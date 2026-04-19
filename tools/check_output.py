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


def read_matrix(path: Path) -> list[list[int]]:
    return parse_matrix_lines(path.read_text().splitlines())


def read_combined_case(path: Path) -> tuple[dict[str, str], list[list[int]], list[list[int]], list[list[int]]]:
    metadata: dict[str, str] = {}
    section_map = {
        "BEGIN_MATRIX_A": "matrix_a",
        "BEGIN_MATRIX_B": "matrix_b",
        "BEGIN_MATRIX_C": "matrix_c",
    }
    section_lines = {
        "matrix_a": [],
        "matrix_b": [],
        "matrix_c": [],
    }
    current_section: str | None = None

    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        if line in section_map:
            current_section = section_map[line]
            continue

        if line.startswith("END_MATRIX_"):
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

    if not a or not b or not c:
        raise SystemExit("Combined case file must contain MATRIX_A, MATRIX_B, and MATRIX_C sections.")

    return metadata, a, b, c


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


def compare(got: list[list[int]], exp: list[list[int]]) -> None:
    if len(got) != len(exp):
        raise SystemExit(f"Row count mismatch: got {len(got)} expected {len(exp)}")

    for r, (got_row, exp_row) in enumerate(zip(got, exp)):
        if len(got_row) != len(exp_row):
            raise SystemExit(f"Column count mismatch on row {r}: got {len(got_row)} expected {len(exp_row)}")
        for c, (g, e) in enumerate(zip(got_row, exp_row)):
            if g != e:
                raise SystemExit(f"Mismatch at ({r}, {c}): got {g}, expected {e}")


def load_inputs(paths: list[Path]) -> tuple[str | None, dict[str, str], list[list[int]], list[list[int]], list[list[int]]]:
    if len(paths) == 1:
        metadata, a, b, c = read_combined_case(paths[0])
        return str(paths[0]), metadata, a, b, c

    if len(paths) == 3:
        a = read_matrix(paths[0])
        b = read_matrix(paths[1])
        c = read_matrix(paths[2])
        return None, {}, a, b, c

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
    args = parser.parse_args()

    combined_path, metadata, a, b, c = load_inputs(args.paths)

    n = validate_square_matrix("Matrix A", a)
    validate_square_matrix("Matrix B", b, expected_size=n)
    validate_square_matrix("Matrix C", c, expected_size=n)

    matrix_dim = metadata.get("MATRIX_DIM")
    if matrix_dim is not None and int(matrix_dim) != n:
        raise SystemExit(f"Combined case MATRIX_DIM says {matrix_dim}, but matrix data is {n}x{n}.")

    expected = matmul(a, b)
    compare(c, expected)

    if combined_path is not None:
        cycles = metadata.get("CYCLES")
        if cycles is not None:
            print(f"PASS: {n}x{n} matrix multiply matches software reference. cycles={cycles}")
        else:
            print(f"PASS: {n}x{n} matrix multiply matches software reference. source={combined_path}")
    else:
        print(f"PASS: {n}x{n} matrix multiply matches software reference.")


if __name__ == "__main__":
    main()
