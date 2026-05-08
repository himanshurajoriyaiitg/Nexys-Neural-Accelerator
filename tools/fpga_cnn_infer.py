#!/usr/bin/env python3
from __future__ import annotations

import argparse
import struct
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from fpga_cnn_model import (
    GRID_SIZE,
    MODEL_KIND_DIGIT_LINEAR,
    FpgaCnnModel,
    labels_for_charset,
    load_or_train_model,
    quantize_digit_feature_vector,
    quantize_int8,
)
from handwritten_digit_pipeline import preprocess_handwritten_image

try:
    import serial  # type: ignore
except ImportError:  # pragma: no cover
    serial = None


FRAME_START = 0xA5
CMD_WRITE_A = 0x01
CMD_WRITE_B = 0x02
CMD_WRITE_A_BURST = 0x10
CMD_WRITE_B_BURST = 0x11
CMD_ZERO_A_RUN = 0x12
CMD_ZERO_B_RUN = 0x13
CMD_WRITE_BIAS = 0x07
CMD_START = 0x03
CMD_STATUS = 0x04
CMD_DUMP_C = 0x05
CMD_SET_LED_CODE = 0x20

RESP_ACK = 0x5A
RESP_ERROR = 0xE0
RESP_STATUS = 0xA6
RESP_DUMP = 0xA7

ACT_NONE = "NONE"
ACT_RELU = "RELU"
BURST_MAX_BYTES = 255
ZERO_RUN_THRESHOLD = 8


@dataclass
class BackendMetrics:
    accelerator_calls: int = 0
    total_cycle_count: int = 0
    matrix_upload_bytes: int = 0
    matrix_upload_commands: int = 0


def im2col_same(input_maps: np.ndarray, kernel_h: int, kernel_w: int) -> np.ndarray:
    if input_maps.ndim == 2:
        input_maps = input_maps[None, :, :]
    channels, height, width = input_maps.shape
    pad_h = kernel_h // 2
    pad_w = kernel_w // 2
    padded = np.pad(input_maps, ((0, 0), (pad_h, pad_h), (pad_w, pad_w)), mode="constant")
    rows: list[np.ndarray] = []
    for r in range(height):
        for c in range(width):
            patch = padded[:, r : r + kernel_h, c : c + kernel_w]
            rows.append(patch.reshape(-1))
    return np.stack(rows).astype(np.int8)


def apply_activation(values: np.ndarray, activation: str) -> np.ndarray:
    if activation == ACT_RELU:
        return np.maximum(values, 0)
    return values


def max_pool_2x2(feature_map: np.ndarray) -> np.ndarray:
    h, w = feature_map.shape
    return feature_map.reshape(h // 2, 2, w // 2, 2).max(axis=(1, 3))


class SquareBackend:
    def __init__(self) -> None:
        self.metrics = BackendMetrics()

    def run_square(
        self,
        a_square: np.ndarray,
        b_square: np.ndarray,
        bias: np.ndarray | None,
        activation: str,
        pool: bool,
    ) -> np.ndarray:
        raise NotImplementedError

    def set_led_code(self, code: int) -> None:
        return None

    def reset_metrics(self) -> None:
        self.metrics = BackendMetrics()


class SoftwareSquareBackend(SquareBackend):
    def __init__(self) -> None:
        super().__init__()

    def run_square(
        self,
        a_square: np.ndarray,
        b_square: np.ndarray,
        bias: np.ndarray | None,
        activation: str,
        pool: bool,
    ) -> np.ndarray:
        self.metrics.accelerator_calls += 1
        product = a_square.astype(np.int32) @ b_square.astype(np.int32)
        if bias is not None:
            product = product + bias.astype(np.int32)[None, :]
        product = apply_activation(product, activation)
        if pool:
            return max_pool_2x2(product)
        return product


class FpgaSquareBackend(SquareBackend):
    def __init__(self, port: str, baud: int) -> None:
        super().__init__()
        if serial is None:
            raise SystemExit("pyserial is required for FPGA backend. Install it with `pip install pyserial`.")
        self.ser = serial.Serial(port, baud, timeout=2.0)
        self._last_a_signature: bytes | None = None
        self._last_b_signature: bytes | None = None
        self._last_bias_signature: bytes | None = None

    def close(self) -> None:
        self.ser.close()

    @staticmethod
    def _as_signature(values: np.ndarray) -> bytes:
        return np.ascontiguousarray(values.astype(np.int8)).tobytes()

    @staticmethod
    def _zero_run_len(values: np.ndarray, start_idx: int) -> int:
        count = 0
        total = int(values.size)
        while (start_idx + count) < total and int(values[start_idx + count]) == 0:
            count += 1
        return count

    def _send_burst(self, cmd: int, start_addr: int, values: np.ndarray) -> None:
        packet = bytes([FRAME_START, cmd, (start_addr >> 8) & 0xFF, start_addr & 0xFF, len(values) & 0xFF])
        self.ser.write(packet)
        self.ser.write(values.astype(np.int8).tobytes())
        resp = self.ser.read(1)
        if not resp or resp[0] != RESP_ACK:
            raise SystemExit(f"ACK failed for burst cmd 0x{cmd:02X}")
        self.metrics.matrix_upload_commands += 1
        self.metrics.matrix_upload_bytes += int(len(values))

    def _send_zero_run(self, cmd: int, start_addr: int, count: int) -> None:
        self.ser.write(bytes([FRAME_START, cmd, (start_addr >> 8) & 0xFF, start_addr & 0xFF, count & 0xFF]))
        resp = self.ser.read(1)
        if not resp or resp[0] != RESP_ACK:
            raise SystemExit(f"ACK failed for zero-run cmd 0x{cmd:02X}")
        self.metrics.matrix_upload_commands += 1
        self.metrics.matrix_upload_bytes += int(count)

    def _send_packet(self, cmd: int, addr_hi: int, addr_lo: int, data: int) -> None:
        self.ser.write(bytes([FRAME_START, cmd, addr_hi & 0xFF, addr_lo & 0xFF, data & 0xFF]))
        resp = self.ser.read(1)
        if not resp or resp[0] != RESP_ACK:
            raise SystemExit(f"ACK failed for cmd 0x{cmd:02X}")
        if cmd in {CMD_WRITE_A, CMD_WRITE_B, CMD_WRITE_BIAS}:
            self.metrics.matrix_upload_commands += 1
            self.metrics.matrix_upload_bytes += 1

    def _load_matrix(
        self,
        *,
        values: np.ndarray,
        single_cmd: int,
        burst_cmd: int,
        zero_cmd: int,
        signature_slot: str,
        allow_reuse: bool,
    ) -> None:
        flat_values = np.ascontiguousarray(values.astype(np.int8).reshape(-1))
        signature = flat_values.tobytes()
        if allow_reuse and signature == getattr(self, signature_slot):
            return

        idx = 0
        total = int(flat_values.size)
        while idx < total:
            zero_len = self._zero_run_len(flat_values, idx)
            if zero_len >= ZERO_RUN_THRESHOLD:
                while zero_len > 0:
                    chunk = min(BURST_MAX_BYTES, zero_len)
                    self._send_zero_run(zero_cmd, idx, chunk)
                    idx += chunk
                    zero_len -= chunk
                continue

            burst_start = idx
            burst_len = 0
            while idx < total and burst_len < BURST_MAX_BYTES:
                zero_len = self._zero_run_len(flat_values, idx)
                if zero_len >= ZERO_RUN_THRESHOLD:
                    break
                idx += 1
                burst_len += 1

            if burst_len > 1:
                self._send_burst(burst_cmd, burst_start, flat_values[burst_start:burst_start + burst_len])
            elif burst_len == 1:
                value = int(np.uint8(flat_values[burst_start]))
                self._send_packet(single_cmd, (burst_start >> 8) & 0xFF, burst_start & 0xFF, value)

        setattr(self, signature_slot, signature)

    def _load_bias(self, bias: np.ndarray | None, n: int) -> None:
        if bias is None:
            self._last_bias_signature = None
            return

        bias_vec = np.ascontiguousarray(bias.astype(np.int8).reshape(n))
        signature = bias_vec.tobytes()
        if signature == self._last_bias_signature:
            return

        for col in range(n):
            self._send_packet(CMD_WRITE_BIAS, (col >> 8) & 0xFF, col & 0xFF, int(np.uint8(bias_vec[col])))
        self._last_bias_signature = signature

    def _wait_done(self, timeout_s: float = 5.0) -> int:
        import time

        deadline = time.time() + timeout_s
        while time.time() < deadline:
            self.ser.write(bytes([FRAME_START, CMD_STATUS, 0x00, 0x00, 0x00]))
            resp = self.ser.read(6)
            if len(resp) != 6 or resp[0] != RESP_STATUS:
                time.sleep(0.01)
                continue
            busy = (resp[1] & 0x01) != 0
            done = (resp[1] & 0x02) != 0
            if done and not busy:
                return (resp[2] << 24) | (resp[3] << 16) | (resp[4] << 8) | resp[5]
            time.sleep(0.01)
        raise SystemExit("Timed out waiting for FPGA.")

    def run_square(
        self,
        a_square: np.ndarray,
        b_square: np.ndarray,
        bias: np.ndarray | None,
        activation: str,
        pool: bool,
    ) -> np.ndarray:
        n = int(a_square.shape[0])
        self._load_matrix(
            values=a_square,
            single_cmd=CMD_WRITE_A,
            burst_cmd=CMD_WRITE_A_BURST,
            zero_cmd=CMD_ZERO_A_RUN,
            signature_slot="_last_a_signature",
            allow_reuse=False,
        )
        self._load_matrix(
            values=b_square,
            single_cmd=CMD_WRITE_B,
            burst_cmd=CMD_WRITE_B_BURST,
            zero_cmd=CMD_ZERO_B_RUN,
            signature_slot="_last_b_signature",
            allow_reuse=True,
        )
        self._load_bias(bias, n)

        start_word = n
        if pool:
            start_word |= (1 << 11)
        if bias is not None:
            start_word |= (1 << 12)
        if activation == ACT_RELU:
            start_word |= (1 << 13)

        self._send_packet(CMD_START, (start_word >> 8) & 0xFF, start_word & 0xFF, 0x00)
        cycle_count = self._wait_done()
        self.metrics.accelerator_calls += 1
        self.metrics.total_cycle_count += cycle_count

        self.ser.write(bytes([FRAME_START, CMD_DUMP_C, 0x00, 0x00, 0x00]))
        resp = self.ser.read(1)
        if not resp or resp[0] != RESP_DUMP:
            raise SystemExit("Did not receive FPGA dump response.")
        dim_bytes = self.ser.read(2)
        out_n = (dim_bytes[0] << 8) | dim_bytes[1]
        data = self.ser.read(out_n * out_n * 4)
        if len(data) != out_n * out_n * 4:
            raise SystemExit("Short FPGA dump read.")

        output = np.zeros((out_n, out_n), dtype=np.int32)
        offset = 0
        for r in range(out_n):
            for c in range(out_n):
                output[r, c] = struct.unpack(">i", data[offset:offset + 4])[0]
                offset += 4
        return output

    def set_led_code(self, code: int) -> None:
        self._send_packet(CMD_SET_LED_CODE, 0x00, 0x00, code & 0xFF)


def generalized_matmul(backend: SquareBackend, a: np.ndarray, b: np.ndarray) -> np.ndarray:
    rows, k_dim = a.shape
    k_dim_b, cols = b.shape
    if k_dim != k_dim_b:
        raise ValueError("Inner dimensions do not match for matmul.")

    output = np.zeros((rows, cols), dtype=np.int32)
    max_n = 32
    for col0 in range(0, cols, max_n):
        col_chunk = min(max_n, cols - col0)
        for k0 in range(0, k_dim, max_n):
            k_chunk = min(max_n, k_dim - k0)
            for row0 in range(0, rows, max_n):
                row_chunk = min(max_n, rows - row0)
                n = max(row_chunk, col_chunk, k_chunk)
                a_square = np.zeros((n, n), dtype=np.int8)
                b_square = np.zeros((n, n), dtype=np.int8)
                a_square[:row_chunk, :k_chunk] = a[row0 : row0 + row_chunk, k0 : k0 + k_chunk]
                b_square[:k_chunk, :col_chunk] = b[k0 : k0 + k_chunk, col0 : col0 + col_chunk]
                piece = backend.run_square(a_square, b_square, bias=None, activation=ACT_NONE, pool=False)
                output[row0 : row0 + row_chunk, col0 : col0 + col_chunk] += piece[:row_chunk, :col_chunk]
    return output


def postprocess_feature_map(
    backend: SquareBackend,
    feature_map: np.ndarray,
    bias_value: int,
    activation: str,
    pool: bool,
) -> np.ndarray:
    n = int(feature_map.shape[0])
    a_square = np.asarray(feature_map, dtype=np.int8)
    b_square = np.eye(n, dtype=np.int8)
    bias_vec = np.full((n,), int(np.int8(bias_value)), dtype=np.int8)
    output = backend.run_square(a_square, b_square, bias=bias_vec, activation=activation, pool=pool)
    return output.astype(np.int32)


def run_fpga_cnn_backend(image: np.ndarray, model: FpgaCnnModel, backend: SquareBackend) -> np.ndarray:
    if model.model_kind == MODEL_KIND_DIGIT_LINEAR:
        feature_vector = quantize_digit_feature_vector(image).reshape(1, -1)
        logits = generalized_matmul(backend, feature_vector.astype(np.int8), model.fc_weights.T.astype(np.int8))
        return (logits[0] + model.fc_bias).astype(np.int32)

    image_q = quantize_int8(image, target_peak=16.0)
    raw_features = image_q.reshape(1, -1)

    conv1_patches = im2col_same(image_q, 3, 3)
    conv1_bank = model.conv1_kernels.reshape(model.conv1_kernels.shape[0], -1).T.astype(np.int8)
    conv1_raw = generalized_matmul(backend, conv1_patches, conv1_bank)
    conv1_maps = []
    for filt in range(model.conv1_kernels.shape[0]):
        fmap = quantize_int8(conv1_raw[:, filt].reshape(GRID_SIZE, GRID_SIZE))
        fmap_post = postprocess_feature_map(backend, fmap, int(model.conv1_bias[filt]), activation=ACT_RELU, pool=True)
        conv1_maps.append(fmap_post)
    pool1 = np.stack(conv1_maps).astype(np.int32)
    pool1_q = quantize_int8(pool1)
    pool1_features = pool1_q.reshape(1, -1)

    conv2_patches = im2col_same(pool1_q, 3, 3)
    conv2_bank = model.conv2_kernels.reshape(model.conv2_kernels.shape[0], -1).T.astype(np.int8)
    conv2_raw = generalized_matmul(backend, conv2_patches, conv2_bank)
    conv2_maps = []
    for filt in range(model.conv2_kernels.shape[0]):
        fmap = quantize_int8(conv2_raw[:, filt].reshape(4, 4))
        fmap_post = postprocess_feature_map(backend, fmap, int(model.conv2_bias[filt]), activation=ACT_RELU, pool=True)
        conv2_maps.append(fmap_post)
    pool2 = np.stack(conv2_maps).astype(np.int32)
    pool2_q = quantize_int8(pool2)
    features = np.concatenate([raw_features, pool1_features, pool2_q.reshape(1, -1)], axis=1).astype(np.int8)

    logits = generalized_matmul(backend, features.astype(np.int8), model.fc_weights.T.astype(np.int8))
    logits = logits[0] + model.fc_bias
    return logits.astype(np.int32)


def label_to_led_code(label: str) -> int:
    if len(label) == 1 and label.isdigit():
        return int(label)
    return ord(label[0].upper())


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Run the handwritten recognizer in software or on the FPGA matmul engine. "
            "Digit mode uses the more accurate quantized feature-linear model; "
            "letter/alnum mode keeps the compact CNN-style feature stack."
        )
    )
    parser.add_argument("--backend", choices=["software", "fpga"], default="software")
    parser.add_argument("--port", help="Serial port for FPGA mode, e.g. COM8")
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--charset", choices=["digits", "letters", "alnum"], default="digits")
    parser.add_argument("--image-file", type=Path, required=True)
    parser.add_argument("--invert", action="store_true")
    parser.add_argument("--threshold", type=int)
    parser.add_argument("--pad", type=int, default=2)
    parser.add_argument("--retrain-model", action="store_true")
    parser.add_argument("--set-led", action="store_true", help="In FPGA mode, send the predicted digit or ASCII code back to the board LEDs.")
    args = parser.parse_args()

    model = load_or_train_model(args.charset, force_retrain=args.retrain_model)
    image = preprocess_handwritten_image(
        args.image_file,
        invert=args.invert,
        threshold=args.threshold,
        pad=max(args.pad, 2),
    )

    if args.backend == "software":
        backend: SquareBackend = SoftwareSquareBackend()
        logits = run_fpga_cnn_backend(image, model, backend)
    else:
        if not args.port:
            raise SystemExit("--port is required for FPGA backend.")
        backend = FpgaSquareBackend(args.port, args.baud)
        try:
            logits = run_fpga_cnn_backend(image, model, backend)
        finally:
            backend.close()

    best_index = int(np.argmax(logits))
    predicted = model.labels[best_index]
    exp_logits = np.exp(logits - np.max(logits))
    probabilities = exp_logits / np.sum(exp_logits)

    print(f"Input source : {args.image_file}")
    print(f"Backend      : {args.backend}")
    print(f"Charset      : {args.charset}")
    print("Normalized input:")
    print("\n".join("".join("#" if value >= 4 else "." for value in row) for row in image))
    print("\nProbabilities:")
    for index in np.argsort(-probabilities):
        print(f"  label {model.labels[int(index)]}: {float(probabilities[int(index)]):.6f}")
    print(f"\nPrediction   : {predicted}")
    print(
        "Accel stats  : "
        f"{backend.metrics.accelerator_calls} calls, "
        f"{backend.metrics.total_cycle_count} cycles, "
        f"{backend.metrics.matrix_upload_bytes} upload bytes, "
        f"{backend.metrics.matrix_upload_commands} upload commands"
    )

    if args.backend == "fpga" and args.set_led:
        led_backend = FpgaSquareBackend(args.port, args.baud)
        try:
            led_backend.set_led_code(label_to_led_code(predicted))
        finally:
            led_backend.close()
        print(f"LED code     : {label_to_led_code(predicted)}")


if __name__ == "__main__":
    main()
