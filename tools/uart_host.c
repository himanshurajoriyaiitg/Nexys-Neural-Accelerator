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

#define RESP_ACK    0x5A
#define RESP_ERROR  0xE0
#define RESP_STATUS 0xA6
#define RESP_DUMP   0xA7

#define MAX_RUNTIME_N 255
#define MAX_MATRIX_ELEMS 65535u
#define DEFAULT_UART_BAUD 921600

struct options {
    const char *port;
    const char *matrix_a_path;
    const char *matrix_b_path;
    const char *out_dir;
    int n;
    int baud;
    int timeout_ms;
    unsigned int seed;
    bool use_random;
    bool seed_given;
    bool verbose;
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
            "  %s --port <serial> --random [--n 32] [--seed 1] [--baud 921600] [--out-dir fpga_output] [--verbose]\n"
            "  %s --port <serial> --matrix-a <file> --matrix-b <file> [--n 32] [--baud 921600] [--out-dir fpga_output] [--verbose]\n",
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
    opt->timeout_ms = 30000;
    opt->out_dir = "fpga_output";

    for (i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--port") == 0 && (i + 1) < argc) {
            opt->port = argv[++i];
        } else if (strcmp(argv[i], "--matrix-a") == 0 && (i + 1) < argc) {
            opt->matrix_a_path = argv[++i];
        } else if (strcmp(argv[i], "--matrix-b") == 0 && (i + 1) < argc) {
            opt->matrix_b_path = argv[++i];
        } else if (strcmp(argv[i], "--out-dir") == 0 && (i + 1) < argc) {
            opt->out_dir = argv[++i];
        } else if (strcmp(argv[i], "--n") == 0 && (i + 1) < argc) {
            opt->n = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--baud") == 0 && (i + 1) < argc) {
            opt->baud = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--timeout-ms") == 0 && (i + 1) < argc) {
            opt->timeout_ms = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--seed") == 0 && (i + 1) < argc) {
            opt->seed = (unsigned int)strtoul(argv[++i], NULL, 10);
            opt->seed_given = true;
        } else if (strcmp(argv[i], "--random") == 0) {
            opt->use_random = true;
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

    if (((unsigned int)opt->n * (unsigned int)opt->n) > MAX_MATRIX_ELEMS) {
        fail_msg("Runtime N is too large for the 16-bit UART address field.");
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

static void load_matrix(serial_handle_t handle, uint8_t cmd, const int8_t *mat, int n, int timeout_ms, bool verbose, const char *name)
{
    uint16_t idx;
    uint16_t elems = (uint16_t)(n * n);
    char msg[128];

    for (idx = 0; idx < elems; ++idx) {
        if (verbose && ((idx % 32u) == 0u)) {
            snprintf(msg, sizeof(msg), "Loading %s index %u/%u", name,
                     (unsigned int)idx, (unsigned int)(elems - 1u));
            log_msg(true, msg);
        }
        send_frame(handle, cmd, idx, (uint8_t)mat[idx]);
        wait_ack(handle, timeout_ms, name);
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
    *cycles = ((uint32_t)resp[2] << 24) |
              ((uint32_t)resp[3] << 16) |
              ((uint32_t)resp[4] << 8)  |
              (uint32_t)resp[5];
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

static void dump_matrix_c(serial_handle_t handle, int32_t *mat, int n, int timeout_ms, bool verbose)
{
    uint8_t header[3];
    uint8_t raw[4];
    uint16_t idx;
    uint16_t elems = (uint16_t)(n * n);
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
    if ((int)returned_n != n) {
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

static void write_run_info(const char *path, int n, uint32_t cycles, bool overflow_seen)
{
    FILE *fp = fopen(path, "w");
    if (fp == NULL) {
        fail(path);
    }

    fprintf(fp, "MATRIX_N=%d\n", n);
    fprintf(fp, "CYCLES=%u\n", cycles);
    fprintf(fp, "OVERFLOW=%d\n", overflow_seen ? 1 : 0);
    fclose(fp);
}

int main(int argc, char **argv)
{
    struct options opt;
    serial_handle_t serial_handle;
    size_t elems;
    int8_t *matrix_a;
    int8_t *matrix_b;
    int32_t *matrix_c;
    uint32_t cycles;
    bool overflow_seen;
    char path_buf[512];
    unsigned int seed_value;

    parse_args(argc, argv, &opt);
    ensure_dir(opt.out_dir);

    elems = (size_t)opt.n * (size_t)opt.n;
    matrix_a = (int8_t *)malloc(elems * sizeof(*matrix_a));
    matrix_b = (int8_t *)malloc(elems * sizeof(*matrix_b));
    matrix_c = (int32_t *)malloc(elems * sizeof(*matrix_c));

    if (matrix_a == NULL || matrix_b == NULL || matrix_c == NULL) {
        fail_msg("Failed to allocate host matrices.");
    }

    if (opt.use_random) {
        seed_value = opt.seed_given ? opt.seed : (unsigned int)time(NULL);
        random_matrix(matrix_a, opt.n, &seed_value);
        random_matrix(matrix_b, opt.n, &seed_value);
    } else {
        read_matrix_file(opt.matrix_a_path, matrix_a, opt.n);
        read_matrix_file(opt.matrix_b_path, matrix_b, opt.n);
    }

    snprintf(path_buf, sizeof(path_buf), "%s/matrix_a.txt", opt.out_dir);
    write_matrix_i8(path_buf, matrix_a, opt.n);
    snprintf(path_buf, sizeof(path_buf), "%s/matrix_b.txt", opt.out_dir);
    write_matrix_i8(path_buf, matrix_b, opt.n);

    serial_handle = serial_open(opt.port, opt.baud);
    log_msg(opt.verbose, "Opened serial port.");

    load_matrix(serial_handle, CMD_WRITE_A, matrix_a, opt.n, opt.timeout_ms, opt.verbose, "matrix A");
    load_matrix(serial_handle, CMD_WRITE_B, matrix_b, opt.n, opt.timeout_ms, opt.verbose, "matrix B");
    log_msg(opt.verbose, "Sending START.");
    send_frame(serial_handle, CMD_START, (uint16_t)opt.n, 0);
    wait_ack(serial_handle, opt.timeout_ms, "start");
    cycles = wait_done(serial_handle, opt.timeout_ms, opt.verbose, &overflow_seen);
    log_msg(opt.verbose, "Requesting dump.");
    dump_matrix_c(serial_handle, matrix_c, opt.n, opt.timeout_ms, opt.verbose);

    serial_close(serial_handle);

    snprintf(path_buf, sizeof(path_buf), "%s/matrix_c_fpga.txt", opt.out_dir);
    write_matrix_i32(path_buf, matrix_c, opt.n);
    snprintf(path_buf, sizeof(path_buf), "%s/run_info.txt", opt.out_dir);
    write_run_info(path_buf, opt.n, cycles, overflow_seen);

    printf("Wrote %s/matrix_a.txt\n", opt.out_dir);
    printf("Wrote %s/matrix_b.txt\n", opt.out_dir);
    printf("Wrote %s/matrix_c_fpga.txt\n", opt.out_dir);
    printf("Last reported cycle count: %u\n", cycles);
    printf("Overflow flag: %s\n", overflow_seen ? "SET" : "clear");

    free(matrix_a);
    free(matrix_b);
    free(matrix_c);
    return 0;
}
