#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#include <direct.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>
#ifdef __APPLE__
#include <IOKit/serial/ioss.h>
#endif
#endif

#define FRAME_START 0xA5
#define CMD_WRITE_A 0x01
#define CMD_WRITE_B 0x02
#define CMD_START   0x03
#define CMD_STATUS  0x04
#define CMD_DUMP_C  0x05
#define CMD_PROFILE 0x06
#define CMD_WRITE_BIAS 0x07
#define CMD_WRITE_A_BURST 0x10
#define CMD_WRITE_B_BURST 0x11
#define CMD_ZERO_A_RUN    0x12
#define CMD_ZERO_B_RUN    0x13

#define RESP_ACK    0x5A
#define RESP_ERROR  0xE0
#define RESP_STATUS 0xA6
#define RESP_DUMP   0xA7
#define RESP_PROFILE 0xA8

#define MAX_RUNTIME_N 255
#define MAX_MATRIX_ELEMS 65535u
#define DEFAULT_UART_BAUD 921600
#define DEFAULT_ITERATIONS 1
#define PROFILE_PACKET_BYTES 52u
#define BURST_MAX_BYTES 255u
#define ZERO_RUN_THRESHOLD 4u
#define ACT_NONE 0
#define ACT_RELU 1
#define ACT_LEAKY_RELU 2

struct options {
    const char *port;
    const char *matrix_a_path;
    const char *matrix_b_path;
    const char *bias_vec_path;
    const char *out_dir;
    int n;
    int baud;
    int iterations;
    int timeout_ms;
    int activation;
    unsigned int seed;
    bool use_random;
    bool seed_given;
    bool bias;
    bool pool;
    bool reuse_a;
    bool reuse_b;
    bool disable_pack;
    bool verbose;
};

struct load_stats {
    uint32_t single_cmds;
    uint32_t burst_cmds;
    uint32_t burst_values;
    uint32_t zero_run_cmds;
    uint32_t zero_values;
};

struct profile_data {
    bool busy;
    bool done;
    bool overflow;
    uint16_t matrix_n;
    uint32_t cycles;
    uint32_t clear_c_cycles;
    uint32_t preload_cycles;
    uint32_t clear_acc_cycles;
    uint32_t run_cycles;
    uint32_t wait_load_cycles;
    uint32_t writeback_cycles;
    uint32_t load_overlap_cycles;
    uint32_t buffer_swap_count;
    uint32_t output_tile_count;
    uint32_t k_pass_count;
    uint32_t result_signature;
};

#ifdef _WIN32
typedef HANDLE serial_handle_t;
#define SERIAL_INVALID_HANDLE INVALID_HANDLE_VALUE
#else
typedef int serial_handle_t;
#define SERIAL_INVALID_HANDLE (-1)
#endif

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage:\n"
            "  %s --port <serial> --random [--n 32] [--seed 1] [--bias] [--activation NONE|RELU|LEAKY_RELU] [--pool] [--iterations 4] [--reuse-a] [--reuse-b] [--baud 921600] [--out-dir fpga_output] [--no-pack] [--verbose]\n"
            "  %s --port <serial> --matrix-a <file> --matrix-b <file> [--bias --bias-vec <file>] [--activation NONE|RELU|LEAKY_RELU] [--pool] [--n 32] [--iterations 4] [--reuse-a] [--reuse-b] [--baud 921600] [--out-dir fpga_output] [--no-pack] [--verbose]\n",
            prog, prog);
}

static void fail(const char *msg)
{
    perror(msg);
    exit(1);
}

static void fail_msg(const char *msg)
{
    fprintf(stderr, "%s\n", msg);
    exit(1);
}

static void log_msg(bool verbose, const char *msg)
{
    if (verbose) {
        printf("%s\n", msg);
        fflush(stdout);
    }
}

static int parse_activation_name(const char *name)
{
    if (strcmp(name, "NONE") == 0) {
        return ACT_NONE;
    }
    if (strcmp(name, "RELU") == 0) {
        return ACT_RELU;
    }
    if (strcmp(name, "LEAKY_RELU") == 0) {
        return ACT_LEAKY_RELU;
    }

    fail_msg("Activation must be NONE, RELU, or LEAKY_RELU.");
    return ACT_NONE;
}

static uint32_t next_rand_u32(unsigned int *seed)
{
    *seed = (*seed * 1103515245u) + 12345u;
    return *seed;
}

static void parse_args(int argc, char **argv, struct options *opt)
{
    int i;

    memset(opt, 0, sizeof(*opt));
    opt->n = 32;
    opt->baud = DEFAULT_UART_BAUD;
    opt->iterations = DEFAULT_ITERATIONS;
    opt->timeout_ms = 30000;
    opt->out_dir = "fpga_output";
    opt->activation = ACT_NONE;

    for (i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--port") == 0 && (i + 1) < argc) {
            opt->port = argv[++i];
        } else if (strcmp(argv[i], "--matrix-a") == 0 && (i + 1) < argc) {
            opt->matrix_a_path = argv[++i];
        } else if (strcmp(argv[i], "--matrix-b") == 0 && (i + 1) < argc) {
            opt->matrix_b_path = argv[++i];
        } else if (strcmp(argv[i], "--bias-vec") == 0 && (i + 1) < argc) {
            opt->bias_vec_path = argv[++i];
        } else if (strcmp(argv[i], "--out-dir") == 0 && (i + 1) < argc) {
            opt->out_dir = argv[++i];
        } else if (strcmp(argv[i], "--n") == 0 && (i + 1) < argc) {
            opt->n = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--baud") == 0 && (i + 1) < argc) {
            opt->baud = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--iterations") == 0 && (i + 1) < argc) {
            opt->iterations = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--timeout-ms") == 0 && (i + 1) < argc) {
            opt->timeout_ms = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--seed") == 0 && (i + 1) < argc) {
            opt->seed = (unsigned int)strtoul(argv[++i], NULL, 10);
            opt->seed_given = true;
        } else if (strcmp(argv[i], "--random") == 0) {
            opt->use_random = true;
        } else if (strcmp(argv[i], "--bias") == 0) {
            opt->bias = true;
        } else if (strcmp(argv[i], "--pool") == 0) {
            opt->pool = true;
        } else if (strcmp(argv[i], "--activation") == 0 && (i + 1) < argc) {
            opt->activation = parse_activation_name(argv[++i]);
        } else if (strcmp(argv[i], "--reuse-a") == 0) {
            opt->reuse_a = true;
        } else if (strcmp(argv[i], "--reuse-b") == 0) {
            opt->reuse_b = true;
        } else if (strcmp(argv[i], "--no-pack") == 0) {
            opt->disable_pack = true;
        } else if (strcmp(argv[i], "--verbose") == 0) {
            opt->verbose = true;
        } else {
            usage(argv[0]);
            fail_msg("Bad arguments.");
        }
    }

    if (opt->port == NULL) {
        usage(argv[0]);
        fail_msg("Missing --port.");
    }

    if (opt->n < 1 || opt->n > MAX_RUNTIME_N) {
        fail_msg("Runtime N must satisfy 1 <= N <= 255.");
    }

    if (opt->iterations < 1) {
        fail_msg("iterations must be >= 1.");
    }

    if (((unsigned int)opt->n * (unsigned int)opt->n) > MAX_MATRIX_ELEMS) {
        fail_msg("Runtime N is too large for the 16-bit UART address field.");
    }

    if (opt->pool && ((opt->n % 2) != 0)) {
        fail_msg("Max pooling requires an even runtime N.");
    }

    if (!opt->use_random && (opt->matrix_a_path == NULL || opt->matrix_b_path == NULL)) {
        usage(argv[0]);
        fail_msg("Use --random or provide both --matrix-a and --matrix-b.");
    }
}

static void ensure_dir(const char *path)
{
#ifdef _WIN32
    if (_mkdir(path) != 0 && errno != EEXIST) {
        fail("mkdir");
    }
#else
    struct stat st;

    if (stat(path, &st) == 0) {
        if (!S_ISDIR(st.st_mode)) {
            fail_msg("Output path exists and is not a directory.");
        }
        return;
    }

    if (mkdir(path, 0755) != 0) {
        fail("mkdir");
    }
#endif
}

static void random_matrix(int8_t *mat, int n, unsigned int *seed)
{
    size_t idx;
    size_t elems = (size_t)n * (size_t)n;

    for (idx = 0; idx < elems; ++idx) {
        mat[idx] = (int8_t)((next_rand_u32(seed) % 256u) - 128);
    }
}

static void read_matrix_file(const char *path, int8_t *mat, int n)
{
    FILE *fp;
    size_t idx = 0;
    size_t elems = (size_t)n * (size_t)n;
    int value;

    fp = fopen(path, "r");
    if (fp == NULL) {
        fail(path);
    }

    while (idx < elems && fscanf(fp, "%d", &value) == 1) {
        if (value < -128 || value > 127) {
            fclose(fp);
            fail_msg("Matrix file value out of signed 8-bit range.");
        }
        mat[idx++] = (int8_t)value;
    }

    fclose(fp);

    if (idx != elems) {
        fail_msg("Matrix file does not contain exactly N*N values.");
    }
}

static void read_vector_file(const char *path, int8_t *vec, int n)
{
    FILE *fp;
    int idx = 0;
    int value;

    fp = fopen(path, "r");
    if (fp == NULL) {
        fail(path);
    }

    while (idx < n && fscanf(fp, "%d", &value) == 1) {
        if (value < -128 || value > 127) {
            fclose(fp);
            fail_msg("Bias file value out of signed 8-bit range.");
        }
        vec[idx++] = (int8_t)value;
    }

    fclose(fp);

    if (idx != n) {
        fail_msg("Bias file does not contain exactly N values.");
    }
}

static void write_matrix_i8(const char *path, const int8_t *mat, int n)
{
    FILE *fp;
    int r;
    int c;

    fp = fopen(path, "w");
    if (fp == NULL) {
        fail(path);
    }

    for (r = 0; r < n; ++r) {
        for (c = 0; c < n; ++c) {
            fprintf(fp, "%d", (int)mat[(r * n) + c]);
            if (c != (n - 1)) {
                fputc(' ', fp);
            }
        }
        fputc('\n', fp);
    }

    fclose(fp);
}

static void write_vector_i8(const char *path, const int8_t *vec, int n)
{
    FILE *fp;
    int idx;

    fp = fopen(path, "w");
    if (fp == NULL) {
        fail(path);
    }

    for (idx = 0; idx < n; ++idx) {
        fprintf(fp, "%d", (int)vec[idx]);
        if (idx != (n - 1)) {
            fputc(' ', fp);
        }
    }
    fputc('\n', fp);

    fclose(fp);
}

static void write_matrix_i32(const char *path, const int32_t *mat, int n)
{
    FILE *fp;
    int r;
    int c;

    fp = fopen(path, "w");
    if (fp == NULL) {
        fail(path);
    }

    for (r = 0; r < n; ++r) {
        for (c = 0; c < n; ++c) {
            fprintf(fp, "%d", mat[(r * n) + c]);
            if (c != (n - 1)) {
                fputc(' ', fp);
            }
        }
        fputc('\n', fp);
    }

    fclose(fp);
}

static int output_dim_for_mode(int n, bool pool)
{
    return pool ? (n / 2) : n;
}

static int32_t apply_activation_i32(int32_t value, int activation)
{
    if (activation == ACT_RELU) {
        return (value > 0) ? value : 0;
    }
    if (activation == ACT_LEAKY_RELU) {
        return (value > 0) ? value : (value >> 2);
    }
    return value;
}

static void random_vector(int8_t *vec, int n, unsigned int *seed)
{
    int idx;

    for (idx = 0; idx < n; ++idx) {
        vec[idx] = (int8_t)((next_rand_u32(seed) % 256u) - 128);
    }
}

static void compute_reference(const int8_t *matrix_a,
                              const int8_t *matrix_b,
                              const int8_t *bias,
                              int32_t *matrix_c_ref,
                              int32_t *matrix_c_stage,
                              int n,
                              bool enable_bias,
                              int activation,
                              bool pool)
{
    int r;
    int c;
    int k;
    int out_n = output_dim_for_mode(n, pool);

    for (r = 0; r < n; ++r) {
        for (c = 0; c < n; ++c) {
            int32_t total = 0;
            for (k = 0; k < n; ++k) {
                total += (int32_t)matrix_a[(r * n) + k] * (int32_t)matrix_b[(k * n) + c];
            }
            if (enable_bias) {
                total += (int32_t)bias[c];
            }
            matrix_c_stage[(r * n) + c] = apply_activation_i32(total, activation);
        }
    }

    if (pool) {
        for (r = 0; r < out_n; ++r) {
            for (c = 0; c < out_n; ++c) {
                int src = ((2 * r) * n) + (2 * c);
                int32_t max_val = matrix_c_stage[src];

                if (matrix_c_stage[src + 1] > max_val) {
                    max_val = matrix_c_stage[src + 1];
                }
                if (matrix_c_stage[src + n] > max_val) {
                    max_val = matrix_c_stage[src + n];
                }
                if (matrix_c_stage[src + n + 1] > max_val) {
                    max_val = matrix_c_stage[src + n + 1];
                }
                matrix_c_ref[(r * out_n) + c] = max_val;
            }
        }
    } else {
        for (r = 0; r < n; ++r) {
            for (c = 0; c < n; ++c) {
                matrix_c_ref[(r * n) + c] = matrix_c_stage[(r * n) + c];
            }
        }
    }
}

static void verify_result_or_die(const int32_t *got, const int32_t *expected, int n, int iteration)
{
    int idx;
    int elems = n * n;

    for (idx = 0; idx < elems; ++idx) {
        if (got[idx] != expected[idx]) {
            int row = idx / n;
            int col = idx % n;
            fprintf(stderr,
                    "Verification failed on iteration %d at (%d, %d): got %d expected %d\n",
                    iteration,
                    row,
                    col,
                    got[idx],
                    expected[idx]);
            exit(1);
        }
    }
}

static void join_path(char *dst, size_t dst_len, const char *dir, const char *leaf)
{
    snprintf(dst, dst_len, "%s/%s", dir, leaf);
}

static void sleep_ms(int ms)
{
#ifdef _WIN32
    Sleep((DWORD)ms);
#else
    usleep((useconds_t)ms * 1000u);
#endif
}

static uint64_t monotonic_ms(void)
{
#ifdef _WIN32
    return (uint64_t)GetTickCount();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((uint64_t)ts.tv_sec * 1000u) + ((uint64_t)ts.tv_nsec / 1000000u);
#endif
}

#if !defined(_WIN32) && !defined(__APPLE__)
static speed_t baud_to_termios(int baud)
{
    switch (baud) {
        case 9600: return B9600;
        case 19200: return B19200;
        case 38400: return B38400;
        case 57600: return B57600;
        case 115200: return B115200;
#ifdef B921600
        case 921600: return B921600;
#endif
#ifdef B3000000
        case 3000000: return B3000000;
#endif
        default: fail_msg("Unsupported baud rate on this platform.");
    }
    return B115200;
}
#endif

static serial_handle_t serial_open(const char *port, int baud)
{
#ifdef _WIN32
    HANDLE handle;
    DCB dcb;
    COMMTIMEOUTS timeouts;
    const DWORD serial_buffer_bytes = 1u << 16;
    char full_port[64];

    if (strncmp(port, "\\\\.\\", 4) == 0) {
        snprintf(full_port, sizeof(full_port), "%s", port);
    } else {
        snprintf(full_port, sizeof(full_port), "\\\\.\\%s", port);
    }

    handle = CreateFileA(full_port, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                         OPEN_EXISTING, 0, NULL);
    if (handle == INVALID_HANDLE_VALUE) {
        fail_msg("Could not open serial port.");
    }

    memset(&dcb, 0, sizeof(dcb));
    dcb.DCBlength = sizeof(dcb);
    if (!GetCommState(handle, &dcb)) {
        fail_msg("GetCommState failed.");
    }

    dcb.BaudRate = (DWORD)baud;
    dcb.ByteSize = 8;
    dcb.Parity = NOPARITY;
    dcb.StopBits = ONESTOPBIT;
    dcb.fOutxCtsFlow = FALSE;
    dcb.fOutxDsrFlow = FALSE;
    dcb.fDtrControl = DTR_CONTROL_DISABLE;
    dcb.fRtsControl = RTS_CONTROL_DISABLE;
    dcb.fOutX = FALSE;
    dcb.fInX = FALSE;

    if (!SetCommState(handle, &dcb)) {
        fail_msg("SetCommState failed.");
    }

    /* Give the USB-UART driver enough headroom for sustained matrix dumps. */
    SetupComm(handle, serial_buffer_bytes, serial_buffer_bytes);

    memset(&timeouts, 0, sizeof(timeouts));
    timeouts.ReadIntervalTimeout = 20;
    timeouts.ReadTotalTimeoutConstant = 20;
    timeouts.ReadTotalTimeoutMultiplier = 0;
    timeouts.WriteTotalTimeoutConstant = 20;
    timeouts.WriteTotalTimeoutMultiplier = 0;
    if (!SetCommTimeouts(handle, &timeouts)) {
        fail_msg("SetCommTimeouts failed.");
    }

    PurgeComm(handle, PURGE_RXCLEAR | PURGE_TXCLEAR);
    sleep_ms(200);
    return handle;
#else
    int fd;
    struct termios tty;
    speed_t speed;

    fd = open(port, O_RDWR | O_NOCTTY);
    if (fd < 0) {
        fail(port);
    }

    if (tcgetattr(fd, &tty) != 0) {
        fail("tcgetattr");
    }

    cfmakeraw(&tty);
#ifdef __APPLE__
    speed = B115200;
#else
    speed = baud_to_termios(baud);
#endif
    if (cfsetispeed(&tty, speed) != 0) {
        fail("cfsetispeed");
    }
    if (cfsetospeed(&tty, speed) != 0) {
        fail("cfsetospeed");
    }
    tty.c_cflag |= (CLOCAL | CREAD);
    tty.c_cflag &= ~CSTOPB;
    tty.c_cflag &= ~PARENB;
    #ifdef CRTSCTS
    tty.c_cflag &= ~CRTSCTS;
    #endif
    tty.c_cflag &= ~CSIZE;
    tty.c_cflag |= CS8;
    tty.c_cc[VMIN] = 0;
    tty.c_cc[VTIME] = 1;

    if (tcsetattr(fd, TCSANOW, &tty) != 0) {
        fail("tcsetattr");
    }

#ifdef __APPLE__
    {
        speed_t requested_baud = (speed_t)baud;
        if (ioctl(fd, IOSSIOSPEED, &requested_baud) == -1) {
            fail("IOSSIOSPEED");
        }
    }
#endif

    tcflush(fd, TCIOFLUSH);
    sleep_ms(200);
    return fd;
#endif
}

static void serial_close(serial_handle_t handle)
{
#ifdef _WIN32
    CloseHandle(handle);
#else
    close(handle);
#endif
}

static void write_all(serial_handle_t handle, const uint8_t *buf, size_t len)
{
    size_t written = 0;

    while (written < len) {
#ifdef _WIN32
        DWORD chunk = 0;
        if (!WriteFile(handle, buf + written, (DWORD)(len - written), &chunk, NULL)) {
            fail_msg("WriteFile failed.");
        }
        written += (size_t)chunk;
#else
        ssize_t rc;
        rc = write(handle, buf + written, len - written);
        if (rc < 0) {
            fail("write");
        }
        written += (size_t)rc;
#endif
    }
}

static void read_exact(serial_handle_t handle, uint8_t *buf, size_t len, int timeout_ms, const char *stage)
{
    size_t got = 0;
    uint64_t start_ms = monotonic_ms();

    while (got < len) {
#ifdef _WIN32
        DWORD chunk = 0;
        if (!ReadFile(handle, buf + got, (DWORD)(len - got), &chunk, NULL)) {
            fail_msg("ReadFile failed.");
        }
        if (chunk > 0) {
            got += (size_t)chunk;
            continue;
        }
#else
        ssize_t rc;
        rc = read(handle, buf + got, len - got);
        if (rc < 0) {
            fail("read");
        }
        if (rc > 0) {
            got += (size_t)rc;
            continue;
        }
#endif

        if ((long)(monotonic_ms() - start_ms) >= timeout_ms) {
            fprintf(stderr, "Timeout waiting for UART response during %s.\n", stage);
            exit(1);
        }
        sleep_ms(1);
    }
}

static void send_frame(serial_handle_t handle, uint8_t cmd, uint16_t arg, uint8_t data)
{
    uint8_t frame[5];

    frame[0] = FRAME_START;
    frame[1] = cmd;
    frame[2] = (uint8_t)((arg >> 8) & 0xFFu);
    frame[3] = (uint8_t)(arg & 0xFFu);
    frame[4] = data;
    write_all(handle, frame, sizeof(frame));
}

static void wait_ack(serial_handle_t handle, int timeout_ms, const char *stage)
{
    uint8_t resp;

    read_exact(handle, &resp, 1, timeout_ms, stage);
    if (resp == RESP_ACK) {
        return;
    }
    if (resp == RESP_ERROR) {
        fprintf(stderr, "FPGA returned RESP_ERROR during %s.\n", stage);
        exit(1);
    }
    fprintf(stderr, "Unexpected UART response 0x%02X while waiting for ACK during %s.\n", resp, stage);
    exit(1);
}

static uint32_t read_be32(const uint8_t *buf)
{
    return ((uint32_t)buf[0] << 24) |
           ((uint32_t)buf[1] << 16) |
           ((uint32_t)buf[2] << 8)  |
           (uint32_t)buf[3];
}

static size_t zero_run_len(const int8_t *mat, size_t start_idx, size_t elems)
{
    size_t len = 0;

    while ((start_idx + len) < elems &&
           mat[start_idx + len] == 0 &&
           len < BURST_MAX_BYTES) {
        ++len;
    }

    return len;
}

static void send_single_write(serial_handle_t handle,
                              uint8_t cmd,
                              uint16_t addr,
                              int8_t value,
                              int timeout_ms,
                              struct load_stats *stats,
                              const char *stage)
{
    send_frame(handle, cmd, addr, (uint8_t)value);
    wait_ack(handle, timeout_ms, stage);
    stats->single_cmds += 1u;
}

static void send_burst_write(serial_handle_t handle,
                             uint8_t cmd,
                             uint16_t start_addr,
                             const int8_t *values,
                             uint8_t count,
                             int timeout_ms,
                             struct load_stats *stats,
                             const char *stage)
{
    send_frame(handle, cmd, start_addr, count);
    write_all(handle, (const uint8_t *)values, count);
    wait_ack(handle, timeout_ms, stage);
    stats->burst_cmds += 1u;
    stats->burst_values += count;
}

static void send_zero_run(serial_handle_t handle,
                          uint8_t cmd,
                          uint16_t start_addr,
                          uint8_t count,
                          int timeout_ms,
                          struct load_stats *stats,
                          const char *stage)
{
    send_frame(handle, cmd, start_addr, count);
    wait_ack(handle, timeout_ms, stage);
    stats->zero_run_cmds += 1u;
    stats->zero_values += count;
}

static void load_matrix(serial_handle_t handle,
                        uint8_t single_cmd,
                        uint8_t burst_cmd,
                        uint8_t zero_cmd,
                        const int8_t *mat,
                        int n,
                        int timeout_ms,
                        bool verbose,
                        bool disable_pack,
                        const char *name,
                        struct load_stats *stats)
{
    size_t idx = 0;
    size_t elems = (size_t)n * (size_t)n;
    char msg[160];

    memset(stats, 0, sizeof(*stats));

    while (idx < elems) {
        size_t zr_len = zero_run_len(mat, idx, elems);
        size_t burst_start = idx;
        size_t burst_len = 0;

        if (verbose && ((idx % 256u) == 0u)) {
            snprintf(msg, sizeof(msg), "Loading %s index %u/%u", name,
                     (unsigned int)idx, (unsigned int)(elems - 1u));
            log_msg(true, msg);
        }

        if (!disable_pack && zr_len >= ZERO_RUN_THRESHOLD) {
            while (zr_len > 0) {
                uint8_t chunk = (uint8_t)((zr_len > BURST_MAX_BYTES) ? BURST_MAX_BYTES : zr_len);
                send_zero_run(handle, zero_cmd, (uint16_t)idx, chunk, timeout_ms, stats, name);
                idx += chunk;
                zr_len -= chunk;
            }
            continue;
        }

        if (disable_pack) {
            send_single_write(handle,
                              single_cmd,
                              (uint16_t)idx,
                              mat[idx],
                              timeout_ms,
                              stats,
                              name);
            ++idx;
            continue;
        }

        while (idx < elems && burst_len < BURST_MAX_BYTES) {
            zr_len = zero_run_len(mat, idx, elems);
            if (zr_len >= ZERO_RUN_THRESHOLD) {
                break;
            }
            ++idx;
            ++burst_len;
        }

        if (burst_len > 1u) {
            send_burst_write(handle,
                             burst_cmd,
                             (uint16_t)burst_start,
                             &mat[burst_start],
                             (uint8_t)burst_len,
                             timeout_ms,
                             stats,
                             name);
        } else if (burst_len == 1u) {
            send_single_write(handle,
                              single_cmd,
                              (uint16_t)burst_start,
                              mat[burst_start],
                              timeout_ms,
                              stats,
                              name);
        } else {
            send_single_write(handle,
                              single_cmd,
                              (uint16_t)idx,
                              mat[idx],
                              timeout_ms,
                              stats,
                              name);
            ++idx;
        }
    }
}

static void load_bias_vector(serial_handle_t handle,
                             const int8_t *bias,
                             int n,
                             int timeout_ms,
                             bool verbose)
{
    int idx;
    char msg[96];

    for (idx = 0; idx < n; ++idx) {
        if (verbose && ((idx % 32) == 0)) {
            snprintf(msg, sizeof(msg), "Loading bias index %d/%d", idx, n - 1);
            log_msg(true, msg);
        }

        send_frame(handle, CMD_WRITE_BIAS, (uint16_t)idx, (uint8_t)bias[idx]);
        wait_ack(handle, timeout_ms, "bias");
    }
}

static void query_status(serial_handle_t handle, int timeout_ms, bool *busy, bool *done, bool *overflow, uint32_t *cycles)
{
    uint8_t resp[6];

    send_frame(handle, CMD_STATUS, 0, 0);
    read_exact(handle, resp, sizeof(resp), timeout_ms, "status");

    if (resp[0] != RESP_STATUS) {
        fprintf(stderr, "Bad status response from FPGA: 0x%02X 0x%02X 0x%02X 0x%02X 0x%02X 0x%02X\n",
                resp[0], resp[1], resp[2], resp[3], resp[4], resp[5]);
        exit(1);
    }

    *busy = (resp[1] & 0x01u) != 0;
    *done = (resp[1] & 0x02u) != 0;
    *overflow = (resp[1] & 0x04u) != 0;
    *cycles = read_be32(&resp[2]);
}

static void query_profile(serial_handle_t handle, int timeout_ms, struct profile_data *profile)
{
    uint8_t resp[PROFILE_PACKET_BYTES];

    send_frame(handle, CMD_PROFILE, 0, 0);
    read_exact(handle, resp, sizeof(resp), timeout_ms, "profile");

    if (resp[0] != RESP_PROFILE) {
        fprintf(stderr, "Bad profile response from FPGA: 0x%02X\n", resp[0]);
        exit(1);
    }

    profile->busy = (resp[1] & 0x01u) != 0;
    profile->done = (resp[1] & 0x02u) != 0;
    profile->overflow = (resp[1] & 0x04u) != 0;
    profile->matrix_n = (uint16_t)(((uint16_t)resp[2] << 8) | (uint16_t)resp[3]);
    profile->cycles = read_be32(&resp[4]);
    profile->clear_c_cycles = read_be32(&resp[8]);
    profile->preload_cycles = read_be32(&resp[12]);
    profile->clear_acc_cycles = read_be32(&resp[16]);
    profile->run_cycles = read_be32(&resp[20]);
    profile->wait_load_cycles = read_be32(&resp[24]);
    profile->writeback_cycles = read_be32(&resp[28]);
    profile->load_overlap_cycles = read_be32(&resp[32]);
    profile->buffer_swap_count = read_be32(&resp[36]);
    profile->output_tile_count = read_be32(&resp[40]);
    profile->k_pass_count = read_be32(&resp[44]);
    profile->result_signature = read_be32(&resp[48]);
}

static uint32_t wait_done(serial_handle_t handle, int timeout_ms, bool verbose, bool *overflow_seen)
{
    bool busy;
    bool done;
    bool overflow;
    bool saw_busy = false;
    uint32_t cycles = 0;
    uint64_t start_ms = monotonic_ms();

    *overflow_seen = false;

    while (true) {
        query_status(handle, timeout_ms, &busy, &done, &overflow, &cycles);
        *overflow_seen = *overflow_seen || overflow;
        if (verbose) {
            printf("Status: busy=%d done=%d overflow=%d cycles=%u\n",
                   busy ? 1 : 0, done ? 1 : 0, overflow ? 1 : 0, cycles);
            fflush(stdout);
        }

        if (busy) {
            saw_busy = true;
        }
        if (done && !busy) {
            return cycles;
        }
        if (saw_busy && !busy && !done && cycles == 0u) {
            fail_msg("FPGA reset/abort detected. Controller returned to IDLE.");
        }

        sleep_ms(50);
        if ((long)(monotonic_ms() - start_ms) >= timeout_ms) {
            fail_msg("Timeout waiting for core done.");
        }
    }
}

static void dump_matrix_c(serial_handle_t handle, int32_t *mat, int expected_n, int timeout_ms, bool verbose)
{
    uint8_t header[3];
    uint8_t raw[4];
    uint16_t idx;
    uint16_t elems = (uint16_t)(expected_n * expected_n);
    uint16_t returned_n;
    uint16_t log_step = (elems >= 256u) ? 256u : 32u;

    send_frame(handle, CMD_DUMP_C, 0, 0);
    read_exact(handle, header, sizeof(header), timeout_ms, "dump header");
    if (verbose) {
        printf("Dump header bytes: 0x%02X 0x%02X 0x%02X\n", header[0], header[1], header[2]);
        fflush(stdout);
    }

    if (header[0] != RESP_DUMP) {
        fprintf(stderr, "Bad dump response from FPGA: 0x%02X 0x%02X 0x%02X\n",
                header[0], header[1], header[2]);
        exit(1);
    }

    returned_n = (uint16_t)(((uint16_t)header[1] << 8) | (uint16_t)header[2]);
    if ((int)returned_n != expected_n) {
        fail_msg("Dump size returned by FPGA does not match requested N.");
    }

    for (idx = 0; idx < elems; ++idx) {
        read_exact(handle, raw, sizeof(raw), timeout_ms, "dump payload");
        mat[idx] = (int32_t)(((uint32_t)raw[0] << 24) |
                             ((uint32_t)raw[1] << 16) |
                             ((uint32_t)raw[2] << 8)  |
                             ((uint32_t)raw[3]));
        if (verbose && (((idx % log_step) == 0u) || (idx == (uint16_t)(elems - 1u)))) {
            printf("Dumped C index %u/%u\n", (unsigned int)idx, (unsigned int)(elems - 1u));
            fflush(stdout);
        }
    }
}

static void print_profile_summary(const struct profile_data *profile,
                                  const struct load_stats *a_stats,
                                  const struct load_stats *b_stats,
                                  int iteration,
                                  uint64_t host_elapsed_ms)
{
    printf("Iteration %d summary:\n", iteration);
    printf("  cycles=%u host_ms=%llu overflow=%s signature=0x%08X\n",
           profile->cycles,
           (unsigned long long)host_elapsed_ms,
           profile->overflow ? "SET" : "clear",
           profile->result_signature);
    printf("  stage_cycles clear_c=%u preload=%u clear_acc=%u run=%u wait_load=%u writeback=%u overlap=%u\n",
           profile->clear_c_cycles,
           profile->preload_cycles,
           profile->clear_acc_cycles,
           profile->run_cycles,
           profile->wait_load_cycles,
           profile->writeback_cycles,
           profile->load_overlap_cycles);
    printf("  tiling buffer_swaps=%u output_tiles=%u k_passes=%u\n",
           profile->buffer_swap_count,
           profile->output_tile_count,
           profile->k_pass_count);
    printf("  upload_a single=%u burst=%u burst_vals=%u zero_runs=%u zero_vals=%u\n",
           a_stats->single_cmds,
           a_stats->burst_cmds,
           a_stats->burst_values,
           a_stats->zero_run_cmds,
           a_stats->zero_values);
    printf("  upload_b single=%u burst=%u burst_vals=%u zero_runs=%u zero_vals=%u\n",
           b_stats->single_cmds,
           b_stats->burst_cmds,
           b_stats->burst_values,
           b_stats->zero_run_cmds,
           b_stats->zero_values);
}

static void write_run_info(const char *path,
                           int n,
                           int output_n,
                           int iteration,
                           bool random_mode,
                           bool enable_bias,
                           int activation,
                           bool enable_pool,
                           bool reuse_a,
                           bool reuse_b,
                           bool overflow_seen,
                           uint64_t host_elapsed_ms,
                           const struct load_stats *a_stats,
                           const struct load_stats *b_stats,
                           const struct profile_data *profile)
{
    FILE *fp = fopen(path, "w");
    if (fp == NULL) {
        fail(path);
    }

    fprintf(fp, "MATRIX_N=%d\n", n);
    fprintf(fp, "OUTPUT_N=%d\n", output_n);
    fprintf(fp, "ITERATION=%d\n", iteration);
    fprintf(fp, "RANDOM_MODE=%d\n", random_mode ? 1 : 0);
    fprintf(fp, "BIAS=%d\n", enable_bias ? 1 : 0);
    fprintf(fp, "ACTIVATION=%d\n", activation);
    fprintf(fp, "POOL=%d\n", enable_pool ? 1 : 0);
    fprintf(fp, "REUSE_A=%d\n", reuse_a ? 1 : 0);
    fprintf(fp, "REUSE_B=%d\n", reuse_b ? 1 : 0);
    fprintf(fp, "VERIFY=PASS\n");
    fprintf(fp, "CYCLES=%u\n", profile->cycles);
    fprintf(fp, "OVERFLOW=%d\n", overflow_seen ? 1 : 0);
    fprintf(fp, "HOST_ELAPSED_MS=%llu\n", (unsigned long long)host_elapsed_ms);
    fprintf(fp, "PROFILE_MATRIX_N=%u\n", profile->matrix_n);
    fprintf(fp, "PROFILE_CLEAR_C_CYCLES=%u\n", profile->clear_c_cycles);
    fprintf(fp, "PROFILE_PRELOAD_CYCLES=%u\n", profile->preload_cycles);
    fprintf(fp, "PROFILE_CLEAR_ACC_CYCLES=%u\n", profile->clear_acc_cycles);
    fprintf(fp, "PROFILE_RUN_CYCLES=%u\n", profile->run_cycles);
    fprintf(fp, "PROFILE_WAIT_LOAD_CYCLES=%u\n", profile->wait_load_cycles);
    fprintf(fp, "PROFILE_WRITEBACK_CYCLES=%u\n", profile->writeback_cycles);
    fprintf(fp, "PROFILE_LOAD_OVERLAP_CYCLES=%u\n", profile->load_overlap_cycles);
    fprintf(fp, "PROFILE_BUFFER_SWAPS=%u\n", profile->buffer_swap_count);
    fprintf(fp, "PROFILE_OUTPUT_TILES=%u\n", profile->output_tile_count);
    fprintf(fp, "PROFILE_K_PASSES=%u\n", profile->k_pass_count);
    fprintf(fp, "PROFILE_SIGNATURE=0x%08X\n", profile->result_signature);
    fprintf(fp, "A_SINGLE_CMDS=%u\n", a_stats->single_cmds);
    fprintf(fp, "A_BURST_CMDS=%u\n", a_stats->burst_cmds);
    fprintf(fp, "A_BURST_VALUES=%u\n", a_stats->burst_values);
    fprintf(fp, "A_ZERO_RUN_CMDS=%u\n", a_stats->zero_run_cmds);
    fprintf(fp, "A_ZERO_VALUES=%u\n", a_stats->zero_values);
    fprintf(fp, "B_SINGLE_CMDS=%u\n", b_stats->single_cmds);
    fprintf(fp, "B_BURST_CMDS=%u\n", b_stats->burst_cmds);
    fprintf(fp, "B_BURST_VALUES=%u\n", b_stats->burst_values);
    fprintf(fp, "B_ZERO_RUN_CMDS=%u\n", b_stats->zero_run_cmds);
    fprintf(fp, "B_ZERO_VALUES=%u\n", b_stats->zero_values);
    fclose(fp);
}

int main(int argc, char **argv)
{
    struct options opt;
    serial_handle_t serial_handle;
    size_t elems;
    int8_t *matrix_a;
    int8_t *matrix_b;
    int8_t *bias_vec;
    int32_t *matrix_c;
    int32_t *matrix_c_ref;
    int32_t *matrix_c_stage;
    struct load_stats load_stats_a;
    struct load_stats load_stats_b;
    struct profile_data profile;
    uint32_t cycles;
    bool overflow_seen;
    uint64_t host_start_ms;
    uint64_t host_elapsed_ms;
    uint64_t total_host_ms = 0;
    uint64_t total_cycles = 0;
    char path_buf[512];
    char run_dir[512];
    char summary_path[512];
    FILE *summary_fp = NULL;
    unsigned int seed_value;
    unsigned int bias_seed_value;
    int iteration;
    int output_n;
    uint16_t start_word;

    parse_args(argc, argv, &opt);
    ensure_dir(opt.out_dir);

    elems = (size_t)opt.n * (size_t)opt.n;
    output_n = output_dim_for_mode(opt.n, opt.pool);
    matrix_a = (int8_t *)malloc(elems * sizeof(*matrix_a));
    matrix_b = (int8_t *)malloc(elems * sizeof(*matrix_b));
    bias_vec = (int8_t *)malloc((size_t)opt.n * sizeof(*bias_vec));
    matrix_c = (int32_t *)malloc(elems * sizeof(*matrix_c));
    matrix_c_ref = (int32_t *)malloc(elems * sizeof(*matrix_c_ref));
    matrix_c_stage = (int32_t *)malloc(elems * sizeof(*matrix_c_stage));

    if (matrix_a == NULL || matrix_b == NULL || bias_vec == NULL ||
        matrix_c == NULL || matrix_c_ref == NULL || matrix_c_stage == NULL) {
        fail_msg("Failed to allocate host matrices.");
    }

    if (opt.use_random) {
        seed_value = opt.seed_given ? opt.seed : (unsigned int)time(NULL);
        bias_seed_value = seed_value ^ 0x13579BDFu;
    } else {
        read_matrix_file(opt.matrix_a_path, matrix_a, opt.n);
        read_matrix_file(opt.matrix_b_path, matrix_b, opt.n);
        seed_value = 0u;
        bias_seed_value = 0u;
    }

    if (opt.bias) {
        if (opt.use_random && opt.bias_vec_path == NULL) {
            random_vector(bias_vec, opt.n, &bias_seed_value);
        } else if (opt.bias_vec_path != NULL) {
            read_vector_file(opt.bias_vec_path, bias_vec, opt.n);
        } else {
            fail_msg("Bias mode requires --random or --bias-vec <file>.");
        }
    } else {
        memset(bias_vec, 0, (size_t)opt.n * sizeof(*bias_vec));
    }

    serial_handle = serial_open(opt.port, opt.baud);
    log_msg(opt.verbose, "Opened serial port.");

    if (opt.iterations > 1) {
        join_path(summary_path, sizeof(summary_path), opt.out_dir, "batch_summary.txt");
        summary_fp = fopen(summary_path, "w");
        if (summary_fp == NULL) {
            fail(summary_path);
        }
        fprintf(summary_fp, "iteration,cycles,host_ms,overflow,signature,a_single,a_burst,a_zero,b_single,b_burst,b_zero\n");
    }

    for (iteration = 0; iteration < opt.iterations; ++iteration) {
        bool load_a_this_iter = (iteration == 0) || !opt.reuse_a;
        bool load_b_this_iter = (iteration == 0) || !opt.reuse_b;

        if (opt.use_random) {
            if (load_a_this_iter) {
                random_matrix(matrix_a, opt.n, &seed_value);
            }
            if (load_b_this_iter) {
                random_matrix(matrix_b, opt.n, &seed_value);
            }
            if (opt.bias && (opt.bias_vec_path == NULL)) {
                random_vector(bias_vec, opt.n, &bias_seed_value);
            }
        }

        compute_reference(matrix_a,
                          matrix_b,
                          bias_vec,
                          matrix_c_ref,
                          matrix_c_stage,
                          opt.n,
                          opt.bias,
                          opt.activation,
                          opt.pool);

        if (opt.iterations == 1) {
            snprintf(run_dir, sizeof(run_dir), "%s", opt.out_dir);
        } else {
            snprintf(run_dir, sizeof(run_dir), "%s/iter_%03d", opt.out_dir, iteration);
            ensure_dir(run_dir);
        }

        join_path(path_buf, sizeof(path_buf), run_dir, "matrix_a.txt");
        write_matrix_i8(path_buf, matrix_a, opt.n);
        join_path(path_buf, sizeof(path_buf), run_dir, "matrix_b.txt");
        write_matrix_i8(path_buf, matrix_b, opt.n);
        if (opt.bias) {
            join_path(path_buf, sizeof(path_buf), run_dir, "bias.txt");
            write_vector_i8(path_buf, bias_vec, opt.n);
        }

        memset(&load_stats_a, 0, sizeof(load_stats_a));
        memset(&load_stats_b, 0, sizeof(load_stats_b));

        host_start_ms = monotonic_ms();

        if (load_a_this_iter) {
            load_matrix(serial_handle,
                        CMD_WRITE_A,
                        CMD_WRITE_A_BURST,
                        CMD_ZERO_A_RUN,
                        matrix_a,
                        opt.n,
                        opt.timeout_ms,
                        opt.verbose,
                        opt.disable_pack,
                        "matrix A",
                        &load_stats_a);
        }

        if (load_b_this_iter) {
            load_matrix(serial_handle,
                        CMD_WRITE_B,
                        CMD_WRITE_B_BURST,
                        CMD_ZERO_B_RUN,
                        matrix_b,
                        opt.n,
                        opt.timeout_ms,
                        opt.verbose,
                        opt.disable_pack,
                        "matrix B",
                        &load_stats_b);
        }

        if (opt.bias) {
            log_msg(opt.verbose, "Loading bias vector.");
            load_bias_vector(serial_handle, bias_vec, opt.n, opt.timeout_ms, opt.verbose);
        }

        log_msg(opt.verbose, "Sending START.");
        start_word = (uint16_t)opt.n;
        if (opt.pool) {
            start_word |= (uint16_t)(1u << 11);
        }
        if (opt.bias) {
            start_word |= (uint16_t)(1u << 12);
        }
        start_word |= (uint16_t)((uint16_t)opt.activation << 13);
        send_frame(serial_handle, CMD_START, start_word, 0);
        wait_ack(serial_handle, opt.timeout_ms, "start");
        cycles = wait_done(serial_handle, opt.timeout_ms, opt.verbose, &overflow_seen);
        log_msg(opt.verbose, "Requesting dump.");
        dump_matrix_c(serial_handle, matrix_c, output_n, opt.timeout_ms, opt.verbose);
        query_profile(serial_handle, opt.timeout_ms, &profile);
        host_elapsed_ms = monotonic_ms() - host_start_ms;

        if (profile.matrix_n != (uint16_t)opt.n) {
            fail_msg("Profile matrix dimension does not match requested N.");
        }
        if (profile.cycles != cycles) {
            fail_msg("Profile cycle count does not match status cycle count.");
        }
        if (profile.busy || !profile.done) {
            fail_msg("Profile flags are inconsistent with a completed run.");
        }

        verify_result_or_die(matrix_c, matrix_c_ref, output_n, iteration);

        join_path(path_buf, sizeof(path_buf), run_dir, "matrix_c_fpga.txt");
        write_matrix_i32(path_buf, matrix_c, output_n);
        join_path(path_buf, sizeof(path_buf), run_dir, "run_info.txt");
        write_run_info(path_buf,
                       opt.n,
                       output_n,
                       iteration,
                       opt.use_random,
                       opt.bias,
                       opt.activation,
                       opt.pool,
                       opt.reuse_a,
                       opt.reuse_b,
                       overflow_seen,
                       host_elapsed_ms,
                       &load_stats_a,
                       &load_stats_b,
                       &profile);

        total_cycles += profile.cycles;
        total_host_ms += host_elapsed_ms;

        print_profile_summary(&profile, &load_stats_a, &load_stats_b, iteration, host_elapsed_ms);

        if (summary_fp != NULL) {
            fprintf(summary_fp,
                    "%d,%u,%llu,%d,0x%08X,%u,%u,%u,%u,%u,%u\n",
                    iteration,
                    profile.cycles,
                    (unsigned long long)host_elapsed_ms,
                    overflow_seen ? 1 : 0,
                    profile.result_signature,
                    load_stats_a.single_cmds,
                    load_stats_a.burst_cmds,
                    load_stats_a.zero_run_cmds,
                    load_stats_b.single_cmds,
                    load_stats_b.burst_cmds,
                    load_stats_b.zero_run_cmds);
            fflush(summary_fp);
        }

        if ((iteration + 1) == opt.iterations && opt.iterations > 1) {
            join_path(path_buf, sizeof(path_buf), opt.out_dir, "matrix_a.txt");
            write_matrix_i8(path_buf, matrix_a, opt.n);
            join_path(path_buf, sizeof(path_buf), opt.out_dir, "matrix_b.txt");
            write_matrix_i8(path_buf, matrix_b, opt.n);
            if (opt.bias) {
                join_path(path_buf, sizeof(path_buf), opt.out_dir, "bias.txt");
                write_vector_i8(path_buf, bias_vec, opt.n);
            }
            join_path(path_buf, sizeof(path_buf), opt.out_dir, "matrix_c_fpga.txt");
            write_matrix_i32(path_buf, matrix_c, output_n);
            join_path(path_buf, sizeof(path_buf), opt.out_dir, "run_info.txt");
            write_run_info(path_buf,
                           opt.n,
                           output_n,
                           iteration,
                           opt.use_random,
                           opt.bias,
                           opt.activation,
                           opt.pool,
                           opt.reuse_a,
                           opt.reuse_b,
                           overflow_seen,
                           host_elapsed_ms,
                           &load_stats_a,
                           &load_stats_b,
                           &profile);
        }
    }

    serial_close(serial_handle);
    if (summary_fp != NULL) {
        fclose(summary_fp);
    }

    printf("Wrote %s/matrix_a.txt\n", opt.out_dir);
    printf("Wrote %s/matrix_b.txt\n", opt.out_dir);
    if (opt.bias) {
        printf("Wrote %s/bias.txt\n", opt.out_dir);
    }
    printf("Wrote %s/matrix_c_fpga.txt\n", opt.out_dir);
    printf("Verified %d iteration(s) successfully.\n", opt.iterations);
    printf("Aggregate cycles: %llu\n", (unsigned long long)total_cycles);
    printf("Aggregate host time (ms): %llu\n", (unsigned long long)total_host_ms);

    free(matrix_a);
    free(matrix_b);
    free(bias_vec);
    free(matrix_c);
    free(matrix_c_ref);
    free(matrix_c_stage);
    return 0;
}
