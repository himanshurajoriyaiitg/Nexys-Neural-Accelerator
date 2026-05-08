import argparse
import serial
import struct
import time
import os
import random
import numpy as np
import sys

# UART Commands
FRAME_START = 0xA5
CMD_WRITE_A = 0x01
CMD_WRITE_B = 0x02
CMD_START   = 0x03
CMD_STATUS  = 0x04
CMD_DUMP_C  = 0x05
CMD_WRITE_BIAS = 0x07
CMD_WRITE_A_BURST = 0x10
CMD_WRITE_B_BURST = 0x11

RESP_ACK    = 0x5A
RESP_STATUS = 0xA6
RESP_DUMP   = 0xA7
RESP_ERROR  = 0xE0

def send_burst_write(ser, cmd, start_addr, values):
    count = len(values)
    packet = bytes([FRAME_START, cmd, (start_addr >> 8) & 0xFF, start_addr & 0xFF, count & 0xFF])
    ser.write(packet)
    ser.write(values.tobytes())
    resp = ser.read(1)
    if not resp or resp[0] != RESP_ACK:
        print(f"Error: Did not receive ACK for burst cmd 0x{cmd:02X}. Received {resp.hex() if resp else 'Nothing'}")
        sys.exit(1)

def send_packet(ser, cmd, addr_hi, addr_lo, data, expect_ack=True):
    packet = bytes([FRAME_START, cmd, addr_hi, addr_lo, data])
    ser.write(packet)
    if expect_ack:
        resp = ser.read(1)
        if not resp or resp[0] != RESP_ACK:
            print(f"Error: Did not receive ACK for cmd 0x{cmd:02X}. Received {resp.hex() if resp else 'Nothing'}")
            sys.exit(1)

def wait_for_done(ser, timeout_s=5.0):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        ser.write(bytes([FRAME_START, CMD_STATUS, 0x00, 0x00, 0x00]))
        resp = ser.read(6)
        if len(resp) != 6 or resp[0] != RESP_STATUS:
            time.sleep(0.01)
            continue

        busy = (resp[1] & 0x01) != 0
        done = (resp[1] & 0x02) != 0
        if done and not busy:
            return
        time.sleep(0.01)

    print("Error: Timed out waiting for TPU completion.")
    sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="FPGA TPU Host Controller")
    parser.add_argument("--port", type=str, required=True, help="COM port (e.g. COM8 or /dev/ttyUSB0)")
    parser.add_argument("--baud", type=int, default=921600, help="Baud rate (default: 921600)")
    parser.add_argument("--n", type=int, required=True, help="Matrix dimension N")
    parser.add_argument("--matrix-a", type=str, default="RANDOM", help="Path to Matrix A text file, or 'RANDOM' (default)")
    parser.add_argument("--matrix-b", type=str, default="RANDOM", help="Path to Matrix B text file, or 'RANDOM' (default)")
    parser.add_argument("--bias-vec", type=str, default="RANDOM", help="Path to Bias 1D text file, or 'RANDOM' (default)")
    parser.add_argument("--seed", type=int, default=1, help="Random seed")
    parser.add_argument("--out-dir", type=str, default="fpga_output", help="Output directory")
    parser.add_argument("--verbose", action="store_true", help="Verbose output")
    
    # Modes
    parser.add_argument("--bias", action="store_true", help="Enable Bias Addition")
    parser.add_argument("--activation", type=str, choices=["NONE", "RELU", "LEAKY_RELU"], default="NONE", help="Activation Function")
    parser.add_argument("--pool", action="store_true", help="Enable 2x2 Max Pooling")
    
    args = parser.parse_args()
    
    os.makedirs(args.out_dir, exist_ok=True)
    np.random.seed(args.seed)
    
    N = args.n
    if args.pool and N % 2 != 0:
        print("Error: For Max Pooling, matrix dimension N must be even.")
        sys.exit(1)

    print(f"=== TPU Host Configuration ===")
    print(f"Dimension : {N}x{N}")
    print(f"Bias      : {'ENABLED' if args.bias else 'DISABLED'}")
    print(f"Act Mode  : {args.activation}")
    print(f"Max Pool  : {'ENABLED' if args.pool else 'DISABLED'}")
    
    # Generate or Load Matrices Independently
    try:
        if args.matrix_a == "RANDOM":
            A = np.random.randint(-16, 16, size=(N, N), dtype=np.int8)
        else:
            A = np.loadtxt(args.matrix_a, dtype=np.int8).reshape((N, N))

        if args.matrix_b == "RANDOM":
            B = np.random.randint(-16, 16, size=(N, N), dtype=np.int8)
        else:
            B = np.loadtxt(args.matrix_b, dtype=np.int8).reshape((N, N))

        if not args.bias:
            Bias = np.zeros((N,), dtype=np.int8)
        elif args.bias_vec == "RANDOM":
            Bias = np.random.randint(-16, 16, size=(N,), dtype=np.int8)
        else:
            Bias = np.loadtxt(args.bias_vec, dtype=np.int8).flatten()

    except Exception as e:
        print(f"Error loading matrix files: {e}")
        print(f"Make sure custom files exist and have {N*N} or {N} values.")
        sys.exit(1)
    
    # Compute Software Reference
    C_ref = np.zeros((N, N), dtype=np.int32)
    for r in range(N):
        for c in range(N):
            val = np.dot(A[r, :].astype(np.int32), B[:, c].astype(np.int32))
            if args.bias:
                val += int(Bias[c])
            
            # Activation
            if args.activation == "RELU":
                val = max(0, val)
            elif args.activation == "LEAKY_RELU":
                val = val if val > 0 else val >> 2
                
            C_ref[r, c] = val

    if args.pool:
        out_dim = N // 2
        C_pool = np.zeros((out_dim, out_dim), dtype=np.int32)
        for r in range(out_dim):
            for c in range(out_dim):
                window = C_ref[r*2:r*2+2, c*2:c*2+2]
                C_pool[r, c] = np.max(window)
        C_ref = C_pool
    else:
        out_dim = N

    print("Opening serial port...")
    try:
        ser = serial.Serial(args.port, args.baud, timeout=2.0)
    except Exception as e:
        print(f"Failed to open port {args.port}: {e}")
        sys.exit(1)
        
    print("Writing A Matrix (Burst)...")
    A_flat = A.flatten()
    for i in range(0, len(A_flat), 255):
        chunk = A_flat[i:i+255]
        send_burst_write(ser, CMD_WRITE_A_BURST, i, chunk)

    print("Writing B Matrix (Burst)...")
    B_flat = B.flatten()
    for i in range(0, len(B_flat), 255):
        chunk = B_flat[i:i+255]
        send_burst_write(ser, CMD_WRITE_B_BURST, i, chunk)

    if args.bias:
        print("Writing Bias Vector...")
        for c in range(N):
            send_packet(ser, CMD_WRITE_BIAS, (c >> 8) & 0xFF, c & 0xFF, int(Bias[c]) & 0xFF)
            
    # Start Command
    # Bit 11: pool, Bit 12: bias, Bit 14:13: act_mode
    start_word = N
    if args.pool: start_word |= (1 << 11)
    if args.bias: start_word |= (1 << 12)
    if args.activation == "RELU": start_word |= (1 << 13)
    if args.activation == "LEAKY_RELU": start_word |= (2 << 13)
    
    print(f"Starting TPU with Config Word: 0x{start_word:04X}...")
    send_packet(ser, CMD_START, (start_word >> 8) & 0xFF, start_word & 0xFF, 0x00)
    
    # Wait for completion
    wait_for_done(ser)
    
    # Read Result
    print(f"Dumping Output Matrix ({out_dim}x{out_dim})...")
    ser.write(bytes([FRAME_START, CMD_DUMP_C, 0x00, 0x00, 0x00]))
    
    # Expect RESP_DUMP + DIM_HI + DIM_LO + N*N*4 bytes
    resp = ser.read(1)
    if not resp or resp[0] != RESP_DUMP:
        print("Error: Did not receive dump response!")
        sys.exit(1)
        
    dim_bytes = ser.read(2)
    hw_out_dim = (dim_bytes[0] << 8) | dim_bytes[1]
    if hw_out_dim != out_dim:
        print(f"Warning: FPGA returned dim {hw_out_dim}, but expected {out_dim}")
        
    expected_bytes = hw_out_dim * hw_out_dim * 4
    data = ser.read(expected_bytes)
    
    if len(data) != expected_bytes:
        print(f"Error: Read {len(data)} bytes, expected {expected_bytes}")
        sys.exit(1)
        
    C_hw = np.zeros((out_dim, out_dim), dtype=np.int32)
    idx = 0
    for r in range(out_dim):
        for c in range(out_dim):
            # Big Endian Read
            val = struct.unpack('>i', data[idx:idx+4])[0]
            C_hw[r, c] = val
            idx += 4
            
    # Verify
    errors = 0
    for r in range(out_dim):
        for c in range(out_dim):
            if C_hw[r, c] != C_ref[r, c]:
                errors += 1
                if args.verbose:
                    print(f"Mismatch at ({r},{c}): HW={C_hw[r, c]} REF={C_ref[r, c]}")
                    
    # Save the data to the output directory so the user can check it manually
    print(f"\nSaving matrices to {args.out_dir}...")
    np.save(os.path.join(args.out_dir, "A.npy"), A)
    np.save(os.path.join(args.out_dir, "B.npy"), B)
    if args.bias:
        np.save(os.path.join(args.out_dir, "Bias.npy"), Bias)
    np.save(os.path.join(args.out_dir, "C_expected.npy"), C_ref)
    np.save(os.path.join(args.out_dir, "C_fpga.npy"), C_hw)
    
    # Also save as human readable txt files
    np.savetxt(os.path.join(args.out_dir, "C_expected.txt"), C_ref, fmt='%d')
    np.savetxt(os.path.join(args.out_dir, "C_fpga.txt"), C_hw, fmt='%d')

    print("\n" + "="*40)
    if errors == 0:
        print(f" SUCCESS: FPGA Output Matches Reference 100%!")
    else:
        print(f" FAILED: {errors} mismatches found.")
    print("="*40)

if __name__ == "__main__":
    main()
