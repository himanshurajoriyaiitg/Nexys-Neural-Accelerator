#!/usr/bin/env python3
from __future__ import annotations

import argparse
import struct
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

from digit_templates import (
    get_demo_samples,
    get_template_bank,
    get_template_variants,
    matrix_to_ascii,
    shift_matrix,
)
from handwritten_digit_pipeline import (
    GRID_SIZE as HANDWRITTEN_GRID_SIZE,
    predict_digit as predict_handwritten_digit,
    preprocess_binary_matrix,
    preprocess_handwritten_image,
    run_self_test as run_handwritten_self_test,
)
from handwritten_character_pipeline import (
    predict_character as predict_handwritten_character,
    run_self_test as run_handwritten_character_self_test,
)

try:
    import serial  # type: ignore
except ImportError:  # pragma: no cover - only needed for FPGA backend
    serial = None


FRAME_START = 0xA5
CMD_WRITE_A_BURST = 0x10
CMD_WRITE_B_BURST = 0x11
CMD_START = 0x03
CMD_STATUS = 0x04
CMD_DUMP_C = 0x05
RESP_ACK = 0x5A
RESP_STATUS = 0xA6
RESP_DUMP = 0xA7


DEFAULT_GRID_SIZE = 32
MAX_GRID_SIZE = 32


def get_labels_for_charset(charset: str) -> list[str]:
    if charset == "digits":
        return [str(i) for i in range(10)]
    if charset == "letters":
        return [chr(code) for code in range(ord("A"), ord("Z") + 1)]
    return [str(i) for i in range(10)] + [chr(code) for code in range(ord("A"), ord("Z") + 1)]


def parse_ascii_or_numeric_matrix(path: Path, grid_size: int) -> np.ndarray:
    rows: list[list[int]] = []
    text_lines = path.read_text().splitlines()
    saw_ascii = any("#" in line or "." in line for line in text_lines)

    for raw_line in text_lines:
        line = raw_line.strip()
        if not line:
            continue
        if saw_ascii:
            rows.append([1 if ch == "#" else -1 for ch in line])
        else:
            rows.append([int(item) for item in line.split()])

    matrix = np.array(rows, dtype=np.int8)
    if matrix.shape != (grid_size, grid_size):
        raise SystemExit(f"Input matrix must be {grid_size}x{grid_size}. Got {matrix.shape}.")
    return np.where(matrix > 0, 1, -1).astype(np.int8)


def load_and_preprocess_image(
    path: Path,
    grid_size: int,
    invert: bool = False,
    threshold: int | None = None,
    pad: int = 0,
) -> np.ndarray:
    image = Image.open(path).convert("L")
    image = ImageOps.autocontrast(image)
    image_np = np.array(image, dtype=np.uint8)

    if invert:
        image_np = 255 - image_np

    auto_threshold = int(image_np.mean())
    used_threshold = threshold if threshold is not None else auto_threshold

    bright_fg = image_np >= used_threshold
    dark_fg = image_np <= used_threshold

    bright_count = int(bright_fg.sum())
    dark_count = int(dark_fg.sum())
    foreground = bright_fg if bright_count <= dark_count else dark_fg

    coords = np.argwhere(foreground)
    if coords.size == 0:
        raise SystemExit(f"Could not find a foreground character region in {path}.")

    top, left = coords.min(axis=0)
    bottom, right = coords.max(axis=0)

    cropped = foreground[top : bottom + 1, left : right + 1].astype(np.uint8) * 255
    cropped_img = Image.fromarray(cropped, mode="L")

    inner_size = grid_size - (2 * pad)
    if inner_size < 1:
        raise SystemExit(f"Pad is too large for {grid_size}x{grid_size} output.")

    width, height = cropped_img.size
    scale = min(inner_size / max(width, 1), inner_size / max(height, 1))
    resized_w = max(1, int(round(width * scale)))
    resized_h = max(1, int(round(height * scale)))
    resized = cropped_img.resize((resized_w, resized_h), Image.Resampling.NEAREST)

    canvas = Image.new("L", (grid_size, grid_size), 0)
    offset_x = (grid_size - resized_w) // 2
    offset_y = (grid_size - resized_h) // 2
    canvas.paste(resized, (offset_x, offset_y))

    normalized = np.array(canvas, dtype=np.uint8)
    return np.where(normalized >= 128, 1, -1).astype(np.int8)


def send_burst_write(ser: "serial.Serial", cmd: int, start_addr: int, values: np.ndarray) -> None:
    packet = bytes([FRAME_START, cmd, (start_addr >> 8) & 0xFF, start_addr & 0xFF, len(values) & 0xFF])
    ser.write(packet)
    ser.write(values.astype(np.int8).tobytes())
    resp = ser.read(1)
    if not resp or resp[0] != RESP_ACK:
        raise SystemExit(
            f"Error: Did not receive ACK for burst cmd 0x{cmd:02X}. "
            f"Received {resp.hex() if resp else 'Nothing'}"
        )


def wait_for_done(ser: "serial.Serial", timeout_s: float = 5.0) -> None:
    import time

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

    raise SystemExit("Error: Timed out waiting for TPU completion.")


def run_fpga_matmul(a_matrix: np.ndarray, b_matrix: np.ndarray, port: str, baud: int) -> np.ndarray:
    if serial is None:
        raise SystemExit("pyserial is required for --backend fpga. Install it with `pip install pyserial`.")

    flat_a = a_matrix.astype(np.int8).flatten()
    flat_b = b_matrix.astype(np.int8).flatten()

    with serial.Serial(port, baud, timeout=2.0) as ser:
        for index in range(0, len(flat_a), 255):
            send_burst_write(ser, CMD_WRITE_A_BURST, index, flat_a[index:index + 255])
        for index in range(0, len(flat_b), 255):
            send_burst_write(ser, CMD_WRITE_B_BURST, index, flat_b[index:index + 255])

        matrix_dim = a_matrix.shape[0]
        ser.write(bytes([FRAME_START, CMD_START, 0x00, matrix_dim & 0xFF, 0x00]))
        ack = ser.read(1)
        if not ack or ack[0] != RESP_ACK:
            raise SystemExit(f"Error: Did not receive ACK for start. Received {ack.hex() if ack else 'Nothing'}")

        wait_for_done(ser)

        ser.write(bytes([FRAME_START, CMD_DUMP_C, 0x00, 0x00, 0x00]))
        resp = ser.read(1)
        if not resp or resp[0] != RESP_DUMP:
            raise SystemExit("Error: Did not receive dump response from FPGA.")

        dim_bytes = ser.read(2)
        out_dim = (dim_bytes[0] << 8) | dim_bytes[1]
        expected_bytes = out_dim * out_dim * 4
        raw = ser.read(expected_bytes)
        if len(raw) != expected_bytes:
            raise SystemExit(f"Error: Read {len(raw)} bytes, expected {expected_bytes}.")

    product = np.zeros((out_dim, out_dim), dtype=np.int32)
    offset = 0
    for r in range(out_dim):
        for c in range(out_dim):
            product[r, c] = struct.unpack(">i", raw[offset:offset + 4])[0]
            offset += 4
    return product


def run_software_matmul(a_matrix: np.ndarray, b_matrix: np.ndarray) -> np.ndarray:
    return a_matrix.astype(np.int32) @ b_matrix.astype(np.int32)


def count_holes(matrix: np.ndarray) -> int:
    fg = matrix > 0
    h, w = fg.shape
    bg = ~fg
    visited = np.zeros((h, w), dtype=bool)
    stack: list[tuple[int, int]] = []

    for r in range(h):
        for c in (0, w - 1):
            if bg[r, c] and not visited[r, c]:
                stack.append((r, c))
                visited[r, c] = True
    for c in range(w):
        for r in (0, h - 1):
            if bg[r, c] and not visited[r, c]:
                stack.append((r, c))
                visited[r, c] = True

    while stack:
        r, c = stack.pop()
        for dr, dc in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            rr = r + dr
            cc = c + dc
            if 0 <= rr < h and 0 <= cc < w and bg[rr, cc] and not visited[rr, cc]:
                visited[rr, cc] = True
                stack.append((rr, cc))

    holes = 0
    for r in range(h):
        for c in range(w):
            if bg[r, c] and not visited[r, c]:
                holes += 1
                stack = [(r, c)]
                visited[r, c] = True
                while stack:
                    rr, cc = stack.pop()
                    for dr, dc in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        nr = rr + dr
                        nc = cc + dc
                        if 0 <= nr < h and 0 <= nc < w and bg[nr, nc] and not visited[nr, nc]:
                            visited[nr, nc] = True
                            stack.append((nr, nc))
    return holes


def extract_shape_features(matrix: np.ndarray) -> dict[str, np.ndarray | float]:
    fg = matrix > 0
    coords = np.argwhere(fg)
    density = float(fg.mean())

    if coords.size == 0:
        zeros = np.zeros(matrix.shape[0], dtype=np.float64)
        return {
            "row_profile": zeros,
            "col_profile": zeros,
            "center": np.array([0.5, 0.5], dtype=np.float64),
            "aspect": 1.0,
            "density": 0.0,
            "holes": 0.0,
        }

    row_profile = fg.mean(axis=1).astype(np.float64)
    col_profile = fg.mean(axis=0).astype(np.float64)
    center = coords.mean(axis=0) / max(matrix.shape[0] - 1, 1)
    top_left = coords.min(axis=0)
    bottom_right = coords.max(axis=0)
    bbox_h = float(bottom_right[0] - top_left[0] + 1)
    bbox_w = float(bottom_right[1] - top_left[1] + 1)
    aspect = bbox_w / max(bbox_h, 1.0)

    return {
        "row_profile": row_profile,
        "col_profile": col_profile,
        "center": center.astype(np.float64),
        "aspect": aspect,
        "density": density,
        "holes": float(count_holes(matrix)),
    }


def software_match_score(image: np.ndarray, template: np.ndarray) -> float:
    img_fg = image > 0
    tmpl_fg = template > 0

    intersection = float(np.logical_and(img_fg, tmpl_fg).sum())
    union = float(np.logical_or(img_fg, tmpl_fg).sum())
    iou = intersection / union if union else 0.0

    image_features = extract_shape_features(image)
    template_features = extract_shape_features(template)

    row_profile_score = 1.0 - float(np.mean(np.abs(image_features["row_profile"] - template_features["row_profile"])))
    col_profile_score = 1.0 - float(np.mean(np.abs(image_features["col_profile"] - template_features["col_profile"])))
    center_gap = float(np.linalg.norm(image_features["center"] - template_features["center"]))
    center_score = max(0.0, 1.0 - center_gap * 1.5)
    aspect_gap = abs(float(image_features["aspect"]) - float(template_features["aspect"]))
    aspect_score = max(0.0, 1.0 - aspect_gap)
    density_gap = abs(float(image_features["density"]) - float(template_features["density"]))
    density_score = max(0.0, 1.0 - density_gap * 3.0)
    hole_gap = abs(float(image_features["holes"]) - float(template_features["holes"]))
    hole_score = max(0.0, 1.0 - hole_gap)

    overlap_score = (intersection * 2.0) - float(np.logical_xor(img_fg, tmpl_fg).sum())
    overlap_score /= float(image.size)

    return (
        (3.5 * iou)
        + (2.0 * overlap_score)
        + (1.6 * row_profile_score)
        + (1.6 * col_profile_score)
        + (1.1 * center_score)
        + (0.9 * aspect_score)
        + (0.9 * density_score)
        + (1.3 * hole_score)
    )


def classify_character(
    image: np.ndarray,
    backend: str,
    port: str | None,
    baud: int,
    grid_size: int,
    charset: str,
) -> tuple[str, dict[str, float], dict[str, np.ndarray]]:
    labels = get_labels_for_charset(charset)
    templates = get_template_bank(grid_size)
    template_variants = get_template_variants(grid_size)
    scores: dict[str, float] = {}
    products: dict[str, np.ndarray] = {}
    shift_step = max(1, grid_size // 32)
    alignment_offsets = ((0, 0), (-shift_step, 0), (shift_step, 0), (0, -shift_step), (0, shift_step))

    for label in labels:
        best_score: float | None = None
        best_product: np.ndarray | None = None
        best_template = templates[label]

        for template in template_variants[label]:
            template_t = template.transpose().copy()
            for dx, dy in alignment_offsets:
                aligned_image = shift_matrix(image, dx=dx, dy=dy)
                if backend == "fpga":
                    if port is None:
                        raise SystemExit("--port is required when backend=fpga.")
                    product = run_fpga_matmul(aligned_image, template_t, port=port, baud=baud)
                    score = float(np.trace(product)) / float(grid_size * grid_size)
                else:
                    product = run_software_matmul(aligned_image, template_t)
                    trace_score = float(np.trace(product)) / float(grid_size * grid_size)
                    shape_score = software_match_score(aligned_image, template)
                    score = (1.2 * trace_score) + (4.0 * shape_score)

                if best_score is None or score > best_score:
                    best_score = score
                    best_product = product
                    best_template = template

        assert best_score is not None
        assert best_product is not None
        products[label] = best_product
        scores[label] = best_score

    best_label = max(scores, key=lambda label: (scores[label], label))
    return best_label, scores, products


def run_template_self_test() -> int:
    failures: list[str] = []
    demo_samples = get_demo_samples(DEFAULT_GRID_SIZE)
    for sample_name, (expected_label, image) in demo_samples.items():
        sample_charset = "digits" if expected_label.isdigit() else "letters"
        predicted, scores, _ = classify_character(
            image,
            backend="software",
            port=None,
            baud=921600,
            grid_size=DEFAULT_GRID_SIZE,
            charset=sample_charset,
        )
        top_score = max(scores.values())
        expected_score = scores[expected_label]
        if expected_score < (top_score - 0.75):
            failures.append(
                f"{sample_name}: expected {expected_label}, predicted {predicted}, "
                f"top score={top_score}, expected score={expected_score}"
            )

    if failures:
        print("Alphanumeric recognizer self-test failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print(f"PASS: alphanumeric recognizer classified {len(demo_samples)} demo samples correctly.")
    return 0


def build_demo_input(label: str) -> np.ndarray:
    templates = get_template_bank(DEFAULT_GRID_SIZE)
    normalized = label.upper()
    if normalized not in templates:
        raise SystemExit(f"Built-in label must be one of 0-9 or A-Z. Got {label}.")
    return templates[normalized]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Recognizer utilities for the matrix-multiplier project."
    )
    parser.add_argument("--pipeline", choices=["template", "handwritten"], default="template")
    parser.add_argument("--backend", choices=["software", "fpga"], default="software")
    parser.add_argument("--port", help="Serial port for FPGA mode, for example COM8.")
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--grid-size", type=int, default=DEFAULT_GRID_SIZE, help="Recognition grid size. FPGA is limited by the programmed matrix size.")
    parser.add_argument("--charset", choices=["digits", "letters", "alnum"], default="digits", help="Restrict recognition classes for better accuracy.")
    parser.add_argument("--label", type=str, help="Use one built-in alphanumeric template as input, for example 3 or A.")
    parser.add_argument("--digit", type=int, help="Backward-compatible alias for built-in digit templates.")
    parser.add_argument("--input-file", type=Path, help="Path to an 8x8 input file using '#' '.' or numeric values.")
    parser.add_argument("--image-file", type=Path, help="Path to a normal image containing one character.")
    parser.add_argument("--invert", action="store_true", help="Invert the image before preprocessing.")
    parser.add_argument("--threshold", type=int, help="Manual grayscale threshold for foreground extraction.")
    parser.add_argument("--pad", type=int, default=0, help="Padding budget inside the normalized 8x8 image.")
    parser.add_argument("--self-test", action="store_true", help="Run the built-in demo test set.")
    parser.add_argument("--show-product", type=str, help="Print the product matrix for one class label, for example A or 7.")
    parser.add_argument("--retrain-model", action="store_true", help="Retrain the cached handwritten-digit model before inference.")
    args = parser.parse_args()

    if args.self_test:
        if args.pipeline == "handwritten":
            if args.charset == "digits":
                train_acc, test_acc = run_handwritten_self_test(force_retrain=args.retrain_model)
                print(
                    "PASS: handwritten digit pipeline trained successfully "
                    f"(train_acc={train_acc:.4f}, test_acc={test_acc:.4f})."
                )
            else:
                train_acc, local_acc = run_handwritten_character_self_test(
                    charset=args.charset,
                    force_retrain=args.retrain_model,
                )
                local_suffix = f", local_acc={local_acc:.4f}" if local_acc is not None else ""
                print(
                    "PASS: handwritten character pipeline trained successfully "
                    f"(train_acc={train_acc:.4f}{local_suffix})."
                )
            raise SystemExit(0)
        raise SystemExit(run_template_self_test())

    if args.grid_size < 8 or args.grid_size > MAX_GRID_SIZE:
        raise SystemExit(f"--grid-size must be between 8 and {MAX_GRID_SIZE} for the current project configuration.")
    if args.backend == "fpga" and args.grid_size > MAX_GRID_SIZE:
        raise SystemExit(f"FPGA backend currently supports up to {MAX_GRID_SIZE}x{MAX_GRID_SIZE} in this repo.")

    built_in_label = args.label.upper() if args.label is not None else (str(args.digit) if args.digit is not None else None)
    selected_sources = [built_in_label is not None, args.input_file is not None, args.image_file is not None]
    if sum(1 for item in selected_sources if item) != 1:
        raise SystemExit("Choose exactly one input source: --label/--digit, --input-file, or --image-file.")

    if args.pipeline == "handwritten":
        if args.backend != "software":
            raise SystemExit("The handwritten pipeline currently runs in software mode only.")
        if args.show_product is not None:
            raise SystemExit("--show-product is only available for the template pipeline.")
        if args.input_file is not None:
            binary_image = parse_ascii_or_numeric_matrix(args.input_file, HANDWRITTEN_GRID_SIZE)
            image = preprocess_binary_matrix(binary_image)
            source_name = str(args.input_file)
        elif args.image_file is not None:
            image = preprocess_handwritten_image(
                args.image_file,
                invert=args.invert,
                threshold=args.threshold,
                pad=max(args.pad, 2),
            )
            source_name = str(args.image_file)
        else:
            if built_in_label is None:
                raise SystemExit("Built-in label is required for handwritten demo input.")
            if args.charset == "digits" and not built_in_label.isdigit():
                raise SystemExit("The handwritten digit pipeline only supports built-in digit labels 0-9.")
            if args.charset == "letters" and not built_in_label.isalpha():
                raise SystemExit("The handwritten character pipeline expects built-in letter labels A-Z.")
            template_image = get_template_bank(HANDWRITTEN_GRID_SIZE)[built_in_label]
            image = preprocess_binary_matrix(template_image)
            source_name = f"built-in label {built_in_label}"

        if args.charset == "digits":
            prediction = predict_handwritten_digit(image, force_retrain=args.retrain_model)
            class_summary = "digits (0-9)"
        elif args.charset in {"letters", "alnum"}:
            prediction = predict_handwritten_character(
                image,
                charset=args.charset,
                force_retrain=args.retrain_model,
            )
            class_summary = "uppercase letters (A-Z)" if args.charset == "letters" else "alphanumeric (0-9, A-Z)"
        else:
            raise SystemExit("Unsupported charset for handwritten pipeline.")

        print(f"Input source : {source_name}")
        print("Pipeline     : handwritten")
        print("Backend      : software")
        print(f"Grid size    : {HANDWRITTEN_GRID_SIZE}x{HANDWRITTEN_GRID_SIZE}")
        print(f"Classes      : {class_summary}")
        print("Normalized input:")
        print(matrix_to_ascii(np.where(prediction.normalized_image >= 4.0, 1, -1).astype(np.int8)))
        print("\nProbabilities:")
        for label in sorted(prediction.probabilities, key=lambda item: (-prediction.probabilities[item], item)):
            print(f"  label {label}: {prediction.probabilities[label]:.6f}")
        print(f"\nPrediction   : {prediction.predicted_label}")
        raise SystemExit(0)

    if args.input_file is not None:
        image = parse_ascii_or_numeric_matrix(args.input_file, args.grid_size)
        source_name = str(args.input_file)
    elif args.image_file is not None:
        image = load_and_preprocess_image(
            args.image_file,
            grid_size=args.grid_size,
            invert=args.invert,
            threshold=args.threshold,
            pad=args.pad,
        )
        source_name = str(args.image_file)
    else:
        image = get_template_bank(args.grid_size)[built_in_label]
        source_name = f"built-in label {built_in_label}"

    predicted, scores, products = classify_character(
        image,
        backend=args.backend,
        port=args.port,
        baud=args.baud,
        grid_size=args.grid_size,
        charset=args.charset,
    )

    print(f"Input source : {source_name}")
    print("Pipeline     : template")
    print(f"Backend      : {args.backend}")
    print(f"Grid size    : {args.grid_size}x{args.grid_size}")
    print(f"Charset      : {args.charset}")
    print("Input image:")
    print(matrix_to_ascii(image))
    print("\nScores:")
    for label in sorted(scores, key=lambda item: (-scores[item], item)):
        print(f"  label {label}: {scores[label]}")
    print(f"\nPrediction   : {predicted}")

    if args.show_product is not None:
        selected_label = args.show_product.upper()
        if selected_label not in products:
            raise SystemExit(f"Unknown class label for --show-product: {args.show_product}")
        print(f"\nProduct matrix for class {selected_label}:")
        product = products[selected_label]
        for row in product:
            print(" ".join(f"{int(value):4d}" for value in row))


if __name__ == "__main__":
    main()
