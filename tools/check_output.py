#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def parse_matrix_lines(lines: list[str]) -> list[list[int]]:
    rows: list[list[int]] = []
    for raw_line in lines:
        line = raw_line.strip()
        if not line:
            continue
        rows.append([int(item) for item in line.split()])
    return rows


def parse_vector_lines(lines: list[str]) -> list[int]:
    values: list[int] = []
    for raw_line in lines:
        line = raw_line.strip()
        if not line:
            continue
        values.extend(int(item) for item in line.split())
    return values


def read_matrix(path: Path) -> list[list[int]]:
    return parse_matrix_lines(path.read_text().splitlines())


def read_vector(path: Path) -> list[int]:
    return parse_vector_lines(path.read_text().splitlines())


def read_combined_case(
    path: Path,
) -> tuple[dict[str, str], list[list[int]], list[list[int]], list[list[int]], list[int] | None]:
    metadata: dict[str, str] = {}
    section_map = {
        "BEGIN_MATRIX_A": "matrix_a",
        "BEGIN_MATRIX_B": "matrix_b",
        "BEGIN_MATRIX_C": "matrix_c",
        "BEGIN_BIAS": "bias",
    }
    section_lines = {
        "matrix_a": [],
        "matrix_b": [],
        "matrix_c": [],
        "bias": [],
    }
    current_section: str | None = None

    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        if line in section_map:
            current_section = section_map[line]
            continue

        if line.startswith("END_"):
            current_section = None
            continue

        if current_section is not None:
            section_lines[current_section].append(line)
            continue

        if "=" in line:
            key, value = line.split("=", 1)
            metadata[key.strip()] = value.strip()

    a = parse_matrix_lines(section_lines["matrix_a"])
    b = parse_matrix_lines(section_lines["matrix_b"])
    c = parse_matrix_lines(section_lines["matrix_c"])
    bias_lines = section_lines["bias"]
    bias = parse_vector_lines(bias_lines) if bias_lines else None

    if not a or not b or not c:
        raise SystemExit("Combined case file must contain MATRIX_A, MATRIX_B, and MATRIX_C sections.")

    return metadata, a, b, c, bias


def matmul(a: list[list[int]], b: list[list[int]]) -> list[list[int]]:
    n = len(a)
    out = [[0 for _ in range(n)] for _ in range(n)]
    for r in range(n):
        for c in range(n):
            total = 0
            for k in range(n):
                total += a[r][k] * b[k][c]
            out[r][c] = total
    return out


def apply_activation(value: int, activation: str) -> int:
    if activation == "RELU":
        return max(0, value)
    if activation == "LEAKY_RELU":
        return value if value > 0 else value >> 2
    return value


def apply_modes(
    base: list[list[int]],
    bias: list[int] | None,
    activation: str,
    pool: bool,
) -> list[list[int]]:
    n = len(base)
    post = [[0 for _ in range(n)] for _ in range(n)]

    for r in range(n):
        for c in range(n):
            value = base[r][c]
            if bias is not None:
                value += bias[c]
            post[r][c] = apply_activation(value, activation)

    if not pool:
        return post

    out_n = n // 2
    pooled = [[0 for _ in range(out_n)] for _ in range(out_n)]
    for r in range(out_n):
        for c in range(out_n):
            window = (
                post[2 * r][2 * c],
                post[2 * r][2 * c + 1],
                post[2 * r + 1][2 * c],
                post[2 * r + 1][2 * c + 1],
            )
            pooled[r][c] = max(window)
    return pooled


def validate_square_matrix(name: str, matrix: list[list[int]], expected_size: int | None = None) -> int:
    if not matrix:
        raise SystemExit(f"{name} must be non-empty.")

    size = len(matrix)
    for row_idx, row in enumerate(matrix):
        if len(row) != size:
            raise SystemExit(f"{name} must be square. Row {row_idx} has length {len(row)} but expected {size}.")

    if expected_size is not None and size != expected_size:
        raise SystemExit(f"{name} size mismatch: got {size} expected {expected_size}.")

    return size


def validate_vector(name: str, values: list[int], expected_size: int) -> None:
    if len(values) != expected_size:
        raise SystemExit(f"{name} size mismatch: got {len(values)} expected {expected_size}.")


def compare(got: list[list[int]], exp: list[list[int]]) -> None:
    if len(got) != len(exp):
        raise SystemExit(f"Row count mismatch: got {len(got)} expected {len(exp)}")

    for r, (got_row, exp_row) in enumerate(zip(got, exp)):
        if len(got_row) != len(exp_row):
            raise SystemExit(f"Column count mismatch on row {r}: got {len(got_row)} expected {len(exp_row)}")
        for c, (g, e) in enumerate(zip(got_row, exp_row)):
            if g != e:
                raise SystemExit(f"Mismatch at ({r}, {c}): got {g}, expected {e}")


def parse_activation_name(raw: str) -> str:
    upper = raw.upper()
    if upper in {"NONE", "RELU", "LEAKY_RELU"}:
        return upper
    raise SystemExit("Activation must be NONE, RELU, or LEAKY_RELU.")


def activation_from_metadata(metadata: dict[str, str]) -> str:
    if "ACTIVATION" in metadata:
        raw = metadata["ACTIVATION"]
        if raw in {"0", "1", "2"}:
            return ["NONE", "RELU", "LEAKY_RELU"][int(raw)]
        return parse_activation_name(raw)
    if "ACT_MODE" in metadata:
        raw = metadata["ACT_MODE"]
        if raw not in {"0", "1", "2"}:
            raise SystemExit(f"Unsupported ACT_MODE value: {raw}")
        return ["NONE", "RELU", "LEAKY_RELU"][int(raw)]
    return "NONE"


def load_inputs(
    paths: list[Path],
    bias_file: Path | None,
) -> tuple[str | None, dict[str, str], list[list[int]], list[list[int]], list[list[int]], list[int] | None]:
    if len(paths) == 1:
        metadata, a, b, c, bias = read_combined_case(paths[0])
        if bias_file is not None:
            bias = read_vector(bias_file)
        return str(paths[0]), metadata, a, b, c, bias

    if len(paths) == 3:
        a = read_matrix(paths[0])
        b = read_matrix(paths[1])
        c = read_matrix(paths[2])
        bias = read_vector(bias_file) if bias_file is not None else None
        return None, {}, a, b, c, bias

    raise SystemExit("Provide either one combined dump file or three files: matrix_a matrix_b matrix_c.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Check matrix multiply output dumped by the Verilog testbench or UART host."
    )
    parser.add_argument(
        "paths",
        nargs="+",
        type=Path,
        help="Either one combined case file or three files: matrix_a matrix_b matrix_c",
    )
    parser.add_argument("--bias-file", type=Path, help="Optional bias vector file.")
    parser.add_argument(
        "--activation",
        choices=["NONE", "RELU", "LEAKY_RELU"],
        help="Optional activation override for three-file input.",
    )
    parser.add_argument("--pool", action="store_true", help="Apply 2x2 max pooling to the software reference.")
    args = parser.parse_args()

    combined_path, metadata, a, b, c, bias = load_inputs(args.paths, args.bias_file)

    n = validate_square_matrix("Matrix A", a)
    validate_square_matrix("Matrix B", b, expected_size=n)

    matrix_dim = metadata.get("MATRIX_DIM")
    if matrix_dim is not None and int(matrix_dim) != n:
        raise SystemExit(f"Combined case MATRIX_DIM says {matrix_dim}, but matrix data is {n}x{n}.")

    bias_enabled = ((metadata.get("BIAS", "0") == "1") if metadata else False) or (bias is not None)
    pool_enabled = (metadata.get("POOL", "0") == "1") if metadata else args.pool
    activation = activation_from_metadata(metadata) if metadata else "NONE"

    if args.activation is not None:
        activation = args.activation
    if args.pool:
        pool_enabled = True
    if bias is not None:
        bias_enabled = True

    if pool_enabled and (n % 2 != 0):
        raise SystemExit("Max pooling requires an even matrix size.")

    if bias_enabled:
        if bias is None:
            raise SystemExit("Bias mode is enabled, but no bias vector was provided.")
        validate_vector("Bias vector", bias, n)
    else:
        bias = None

    expected = apply_modes(matmul(a, b), bias, activation, pool_enabled)
    expected_n = n // 2 if pool_enabled else n
    validate_square_matrix("Matrix C", c, expected_size=expected_n)

    output_dim = metadata.get("OUTPUT_DIM")
    if output_dim is not None and int(output_dim) != expected_n:
        raise SystemExit(f"Combined case OUTPUT_DIM says {output_dim}, but expected {expected_n}.")

    compare(c, expected)

    mode_summary = f"bias={1 if bias_enabled else 0} act={activation} pool={1 if pool_enabled else 0}"
    if combined_path is not None:
        cycles = metadata.get("CYCLES")
        if cycles is not None:
            print(f"PASS: {expected_n}x{expected_n} output matches software reference. {mode_summary} cycles={cycles}")
        else:
            print(f"PASS: {expected_n}x{expected_n} output matches software reference. {mode_summary} source={combined_path}")
    else:
        print(f"PASS: {expected_n}x{expected_n} output matches software reference. {mode_summary}")


if __name__ == "__main__":
    main()
