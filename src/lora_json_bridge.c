/*
 * lora_json_bridge — Semtech UDP packet forwarder to TCP JSON bridge.
 *
 * Listens for Semtech PUSH_DATA packets on a UDP port (default 1700),
 * extracts the rxpk JSON array, flattens each entry into a single JSON
 * line prefixed with "type":"lorawan", and streams it to connected TCP
 * clients (default port 1680).
 *
 * Usage: lora_json_bridge [-p tcp_port] [-u udp_port]
 */

#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#define MAX_CLIENTS    32
#define UDP_BUF_SIZE   4096
#define TCP_BUF_SIZE   4096
#define DEFAULT_UDP_PORT 1700
#define DEFAULT_TCP_PORT 1680

/* Semtech UDP protocol constants. */
#define PROTOCOL_VERSION  2
#define PKT_PUSH_DATA     0x00
#define PKT_PUSH_ACK      0x01
#define PUSH_DATA_HEADER  12   /* version(1) + token(2) + type(1) + gateway_id(8) */

static volatile sig_atomic_t running = 1;

static void handle_signal(int sig) {
    (void)sig;
    running = 0;
}

/* Set a file descriptor to non-blocking mode. */
static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/* Send a PUSH_ACK back to the packet forwarder. */
static void send_push_ack(int udp_fd, const struct sockaddr_in *src,
                          const unsigned char *token) {
    unsigned char ack[4];
    ack[0] = PROTOCOL_VERSION;
    ack[1] = token[0];
    ack[2] = token[1];
    ack[3] = PKT_PUSH_ACK;
    sendto(udp_fd, ack, sizeof(ack), 0,
           (const struct sockaddr *)src, sizeof(*src));
}

/*
 * Find a JSON array value for a given key in a JSON string.
 * Returns a pointer to the opening '[' or NULL if not found.
 * This is intentionally minimal — the Semtech forwarder output is
 * well-structured, so a full JSON parser is unnecessary.
 */
static const char *find_json_array(const char *json, const char *key) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *p = strstr(json, pattern);
    if (!p) return NULL;
    p += strlen(pattern);
    while (*p == ' ' || *p == ':' || *p == '\t' || *p == '\n' || *p == '\r')
        p++;
    if (*p == '[') return p;
    return NULL;
}

/*
 * Extract the next JSON object from an array starting at *pos.
 * Writes the object (without surrounding braces) bounds into *start/*end.
 * Advances *pos past the object.  Returns 1 on success, 0 when no more
 * objects remain.
 *
 * Handles nested braces and quoted strings (including escaped quotes).
 */
static int next_json_object(const char **pos, const char **start,
                            const char **end) {
    const char *p = *pos;
    /* Skip to the opening brace. */
    while (*p && *p != '{') {
        if (*p == ']') return 0;  /* end of array */
        p++;
    }
    if (*p != '{') return 0;

    *start = p;  /* points at '{' */
    int depth = 0;
    int in_string = 0;
    while (*p) {
        if (in_string) {
            if (*p == '\\') { p++; if (*p) p++; continue; }
            if (*p == '"') in_string = 0;
        } else {
            if (*p == '"') in_string = 1;
            else if (*p == '{') depth++;
            else if (*p == '}') { depth--; if (depth == 0) { *end = p; *pos = p + 1; return 1; } }
        }
        p++;
    }
    return 0;
}

/*
 * Format an rxpk object as a flattened JSON line with a "type":"lorawan"
 * prefix.  Writes into buf (size buflen).  Returns bytes written, or 0
 * on truncation.
 */
static int format_rxpk(char *buf, size_t buflen,
                       const char *obj_start, const char *obj_end) {
    /* obj_start points at '{', obj_end points at '}'. */
    size_t inner_len = (size_t)(obj_end - obj_start - 1);
    int n = snprintf(buf, buflen, "{\"type\":\"lorawan\",%.*s}\n",
                     (int)inner_len, obj_start + 1);
    if (n < 0 || (size_t)n >= buflen) return 0;
    return n;
}

/* Write buf to all connected TCP clients; drop any that error. */
static void broadcast(int *clients, int *ncli, const char *buf, size_t len) {
    int i = 0;
    while (i < *ncli) {
        ssize_t w = write(clients[i], buf, len);
        if (w < 0 && (errno == EPIPE || errno == ECONNRESET || errno == EBADF)) {
            close(clients[i]);
            clients[i] = clients[--(*ncli)];
        } else {
            i++;
        }
    }
}

static void usage(const char *prog) {
    fprintf(stderr, "Usage: %s [-p tcp_port] [-u udp_port]\n", prog);
    exit(1);
}

int main(int argc, char *argv[]) {
    int tcp_port = DEFAULT_TCP_PORT;
    int udp_port = DEFAULT_UDP_PORT;

    int opt;
    while ((opt = getopt(argc, argv, "p:u:h")) != -1) {
        switch (opt) {
        case 'p': tcp_port = atoi(optarg); break;
        case 'u': udp_port = atoi(optarg); break;
        default:  usage(argv[0]);
        }
    }

    signal(SIGINT,  handle_signal);
    signal(SIGTERM, handle_signal);
    signal(SIGPIPE, SIG_IGN);

    /* ── UDP socket (receive from packet forwarder) ─────────────────── */
    int udp_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (udp_fd < 0) { perror("socket(udp)"); return 1; }

    int reuse = 1;
    setsockopt(udp_fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in udp_addr = {
        .sin_family      = AF_INET,
        .sin_port        = htons((uint16_t)udp_port),
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    if (bind(udp_fd, (struct sockaddr *)&udp_addr, sizeof(udp_addr)) < 0) {
        perror("bind(udp)"); return 1;
    }

    /* ── TCP listener (serve JSON to Urchin clients) ────────────────── */
    int tcp_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (tcp_fd < 0) { perror("socket(tcp)"); return 1; }

    setsockopt(tcp_fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in tcp_addr = {
        .sin_family      = AF_INET,
        .sin_port        = htons((uint16_t)tcp_port),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    if (bind(tcp_fd, (struct sockaddr *)&tcp_addr, sizeof(tcp_addr)) < 0) {
        perror("bind(tcp)"); return 1;
    }
    if (listen(tcp_fd, 8) < 0) { perror("listen"); return 1; }
    set_nonblocking(tcp_fd);

    fprintf(stderr, "lora_json_bridge: UDP :%d -> TCP :%d\n", udp_port, tcp_port);

    int clients[MAX_CLIENTS];
    int ncli = 0;
    unsigned char udp_buf[UDP_BUF_SIZE];
    char tcp_buf[TCP_BUF_SIZE];

    while (running) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(udp_fd, &rfds);
        FD_SET(tcp_fd, &rfds);
        int maxfd = udp_fd > tcp_fd ? udp_fd : tcp_fd;

        struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
        int ready = select(maxfd + 1, &rfds, NULL, NULL, &tv);
        if (ready < 0) {
            if (errno == EINTR) continue;
            perror("select");
            break;
        }

        /* Accept new TCP clients. */
        if (FD_ISSET(tcp_fd, &rfds)) {
            int cfd = accept(tcp_fd, NULL, NULL);
            if (cfd >= 0) {
                if (ncli < MAX_CLIENTS) {
                    set_nonblocking(cfd);
                    clients[ncli++] = cfd;
                } else {
                    close(cfd);
                }
            }
        }

        /* Process incoming UDP packets. */
        if (FD_ISSET(udp_fd, &rfds)) {
            struct sockaddr_in src;
            socklen_t src_len = sizeof(src);
            ssize_t n = recvfrom(udp_fd, udp_buf, sizeof(udp_buf) - 1, 0,
                                 (struct sockaddr *)&src, &src_len);
            if (n < PUSH_DATA_HEADER) continue;

            udp_buf[n] = '\0';

            if (udp_buf[0] != PROTOCOL_VERSION) continue;
            if (udp_buf[3] != PKT_PUSH_DATA) continue;

            /* ACK the packet forwarder. */
            send_push_ack(udp_fd, &src, &udp_buf[1]);

            /* Parse the JSON payload (starts after the 12-byte header). */
            const char *json = (const char *)&udp_buf[PUSH_DATA_HEADER];
            const char *rxpk = find_json_array(json, "rxpk");
            if (!rxpk) continue;

            const char *pos = rxpk;
            const char *obj_start, *obj_end;
            while (next_json_object(&pos, &obj_start, &obj_end)) {
                int len = format_rxpk(tcp_buf, sizeof(tcp_buf),
                                      obj_start, obj_end);
                if (len > 0 && ncli > 0) {
                    broadcast(clients, &ncli, tcp_buf, (size_t)len);
                }
            }
        }
    }

    /* Cleanup. */
    for (int i = 0; i < ncli; i++) close(clients[i]);
    close(tcp_fd);
    close(udp_fd);
    fprintf(stderr, "lora_json_bridge: shutdown\n");
    return 0;
}
