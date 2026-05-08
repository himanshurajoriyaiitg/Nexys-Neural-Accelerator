from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


ASCII_DIGIT_TEMPLATES: dict[str, tuple[str, ...]] = {
    "0": ("..####..", ".##..##.", "##....##", "##....##", "##....##", "##....##", ".##..##.", "..####.."),
    "1": ("...##...", "..###...", ".####...", "...##...", "...##...", "...##...", "...##...", ".######."),
    "2": ("..####..", ".##..##.", ".....##.", "....##..", "...##...", "..##....", ".##.....", ".######."),
    "3": ("..####..", ".##..##.", ".....##.", "...###..", ".....##.", ".....##.", ".##..##.", "..####.."),
    "4": ("....##..", "...###..", "..####..", ".##.##..", "##..##..", "########", "....##..", "....##.."),
    "5": (".######.", ".##.....", ".#####..", ".....##.", ".....##.", ".....##.", ".##..##.", "..####.."),
    "6": ("..####..", ".##..##.", ".##.....", ".#####..", ".##..##.", ".##..##.", ".##..##.", "..####.."),
    "7": (".######.", ".....##.", "....##..", "...##...", "..##....", "..##....", "..##....", "..##...."),
    "8": ("..####..", ".##..##.", ".##..##.", "..####..", ".##..##.", ".##..##.", ".##..##.", "..####.."),
    "9": ("..####..", ".##..##.", ".##..##.", ".##..##.", "..#####.", ".....##.", ".##..##.", "..####.."),
}

ASCII_LETTER_TEMPLATES: dict[str, tuple[str, ...]] = {
    "A": ("...##...", "..####..", ".##..##.", ".##..##.", ".######.", ".##..##.", ".##..##.", ".##..##."),
    "B": (".#####..", ".##..##.", ".##..##.", ".#####..", ".##..##.", ".##..##.", ".##..##.", ".#####.."),
    "C": ("..####..", ".##..##.", ".##.....", ".##.....", ".##.....", ".##.....", ".##..##.", "..####.."),
    "D": (".#####..", ".##..##.", ".##...##", ".##...##", ".##...##", ".##...##", ".##..##.", ".#####.."),
    "E": (".######.", ".##.....", ".##.....", ".#####..", ".##.....", ".##.....", ".##.....", ".######."),
    "F": (".######.", ".##.....", ".##.....", ".#####..", ".##.....", ".##.....", ".##.....", ".##....."),
    "G": ("..####..", ".##..##.", ".##.....", ".##.....", ".##.###.", ".##..##.", ".##..##.", "..####.."),
    "H": (".##..##.", ".##..##.", ".##..##.", ".######.", ".##..##.", ".##..##.", ".##..##.", ".##..##."),
    "I": (".######.", "...##...", "...##...", "...##...", "...##...", "...##...", "...##...", ".######."),
    "J": ("...####.", ".....##.", ".....##.", ".....##.", ".....##.", ".##..##.", ".##..##.", "..####.."),
    "K": (".##..##.", ".##.##..", ".####...", ".###....", ".####...", ".##.##..", ".##..##.", ".##..##."),
    "L": (".##.....", ".##.....", ".##.....", ".##.....", ".##.....", ".##.....", ".##.....", ".######."),
    "M": (".##..##.", ".######.", ".######.", ".##.###.", ".##..##.", ".##..##.", ".##..##.", ".##..##."),
    "N": (".##..##.", ".###.##.", ".######.", ".######.", ".##.###.", ".##..##.", ".##..##.", ".##..##."),
    "O": ("..####..", ".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##..##.", "..####.."),
    "P": (".#####..", ".##..##.", ".##..##.", ".#####..", ".##.....", ".##.....", ".##.....", ".##....."),
    "Q": ("..####..", ".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##.###.", ".##..##.", "..#####."),
    "R": (".#####..", ".##..##.", ".##..##.", ".#####..", ".####...", ".##.##..", ".##..##.", ".##..##."),
    "S": ("..####..", ".##..##.", ".##.....", "..####..", ".....##.", ".....##.", ".##..##.", "..####.."),
    "T": (".######.", "...##...", "...##...", "...##...", "...##...", "...##...", "...##...", "...##..."),
    "U": (".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##..##.", "..####.."),
    "V": (".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##..##.", "..####..", "..####..", "...##..."),
    "W": (".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##.###.", ".######.", ".######.", ".##..##."),
    "X": (".##..##.", ".##..##.", "..####..", "...##...", "...##...", "..####..", ".##..##.", ".##..##."),
    "Y": (".##..##.", ".##..##.", "..####..", "...##...", "...##...", "...##...", "...##...", "...##..."),
    "Z": (".######.", ".....##.", "....##..", "...##...", "..##....", ".##.....", ".##.....", ".######."),
}


def ascii_to_matrix(lines: tuple[str, ...] | list[str]) -> np.ndarray:
    matrix = np.array([[1 if ch == "#" else -1 for ch in line.strip()] for line in lines], dtype=np.int8)
    if matrix.shape != (8, 8):
        raise ValueError(f"Character matrix must be 8x8, got {matrix.shape}")
    return matrix


def matrix_to_ascii(matrix: np.ndarray) -> str:
    return "\n".join("".join("#" if int(value) > 0 else "." for value in row) for row in matrix)


def shift_matrix(matrix: np.ndarray, dx: int, dy: int) -> np.ndarray:
    shifted = np.full_like(matrix, -1)
    for r in range(matrix.shape[0]):
        for c in range(matrix.shape[1]):
            src_r = r - dy
            src_c = c - dx
            if 0 <= src_r < matrix.shape[0] and 0 <= src_c < matrix.shape[1]:
                shifted[r, c] = matrix[src_r, src_c]
    return shifted


def thicken_matrix(matrix: np.ndarray) -> np.ndarray:
    thick = matrix.copy()
    for r, c in np.argwhere(matrix > 0):
        for dr, dc in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            rr = r + dr
            cc = c + dc
            if 0 <= rr < matrix.shape[0] and 0 <= cc < matrix.shape[1]:
                thick[rr, cc] = 1
    return thick


def add_sparse_noise(matrix: np.ndarray, points: list[tuple[int, int]]) -> np.ndarray:
    noisy = matrix.copy()
    for r, c in points:
        if 0 <= r < matrix.shape[0] and 0 <= c < matrix.shape[1]:
            noisy[r, c] *= -1
    return noisy


def get_font_candidates() -> list[Path]:
    return [
        Path("C:/Windows/Fonts/consola.ttf"),
        Path("C:/Windows/Fonts/arial.ttf"),
        Path("C:/Windows/Fonts/calibri.ttf"),
        Path("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"),
        Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
    ]


def _find_font(font_size: int, preferred_path: Path | None = None) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [preferred_path] if preferred_path is not None else []
    candidates.extend(get_font_candidates())
    for candidate in candidates:
        if candidate is not None and candidate.exists():
            try:
                return ImageFont.truetype(str(candidate), font_size)
            except OSError:
                continue
    return ImageFont.load_default()


def render_label_template(label: str, grid_size: int, preferred_font: Path | None = None, font_scale: float = 0.9) -> np.ndarray:
    if grid_size == 8:
        merged = {}
        merged.update(ASCII_DIGIT_TEMPLATES)
        merged.update(ASCII_LETTER_TEMPLATES)
        if label not in merged:
            raise KeyError(label)
        return ascii_to_matrix(merged[label])

    canvas = Image.new("L", (grid_size, grid_size), 0)
    draw = ImageDraw.Draw(canvas)
    font = _find_font(max(12, int(grid_size * font_scale)), preferred_font)
    bbox = draw.textbbox((0, 0), label, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    x = (grid_size - text_w) // 2 - bbox[0]
    y = (grid_size - text_h) // 2 - bbox[1]
    draw.text((x, y), label, fill=255, font=font)
    pixels = np.array(canvas, dtype=np.uint8)
    return np.where(pixels >= 128, 1, -1).astype(np.int8)


def get_template_bank(grid_size: int = 8) -> dict[str, np.ndarray]:
    labels = [str(i) for i in range(10)] + [chr(code) for code in range(ord("A"), ord("Z") + 1)]
    return {label: render_label_template(label, grid_size) for label in labels}


def get_template_variants(grid_size: int = 8) -> dict[str, list[np.ndarray]]:
    labels = [str(i) for i in range(10)] + [chr(code) for code in range(ord("A"), ord("Z") + 1)]
    if grid_size == 8:
        return {label: [render_label_template(label, grid_size)] for label in labels}

    available_fonts = [path for path in get_font_candidates() if path.exists()]
    font_choices = available_fonts[:2] if available_fonts else [None]
    scales = (0.86, 0.96)

    variants: dict[str, list[np.ndarray]] = {}
    for label in labels:
        label_variants: list[np.ndarray] = []
        for font_path in font_choices:
            for scale in scales:
                label_variants.append(render_label_template(label, grid_size, preferred_font=font_path, font_scale=scale))
        variants[label] = label_variants
    return variants


def get_demo_samples(grid_size: int = 8) -> dict[str, tuple[str, np.ndarray]]:
    templates = get_template_bank(grid_size)
    samples: dict[str, tuple[str, np.ndarray]] = {}

    for label in "0123456789":
        samples[f"digit_{label}_clean"] = (label, templates[label])
    for label in ("A", "B", "C", "E", "H", "K", "M", "N", "R", "X", "Y", "Z"):
        samples[f"letter_{label}_clean"] = (label, templates[label])

    scale = max(1, grid_size // 16)
    samples["digit_0_shifted"] = ("0", shift_matrix(templates["0"], dx=scale, dy=0))
    samples["digit_1_shifted"] = ("1", shift_matrix(templates["1"], dx=-scale, dy=0))
    samples["digit_2_thick"] = ("2", thicken_matrix(templates["2"]))
    samples["digit_3_noisy"] = ("3", add_sparse_noise(templates["3"], [(2 * scale, 2 * scale), (4 * scale, 4 * scale)]))
    samples["digit_4_shifted"] = ("4", shift_matrix(templates["4"], dx=0, dy=-scale))
    samples["digit_5_noisy"] = ("5", add_sparse_noise(templates["5"], [(2 * scale, 5 * scale), (6 * scale, 4 * scale)]))
    samples["digit_6_noisy"] = ("6", add_sparse_noise(templates["6"], [(scale, 2 * scale), (grid_size - scale - 1, 4 * scale)]))
    samples["digit_7_shifted"] = ("7", shift_matrix(templates["7"], dx=0, dy=scale))
    samples["digit_8_noisy"] = ("8", add_sparse_noise(templates["8"], [(scale, scale), (grid_size - scale - 1, grid_size - scale - 1)]))
    samples["digit_9_noisy"] = ("9", add_sparse_noise(templates["9"], [(scale, scale), (5 * scale, 5 * scale)]))

    samples["letter_A_thick"] = ("A", thicken_matrix(templates["A"]))
    samples["letter_B_noisy"] = ("B", add_sparse_noise(templates["B"], [(scale, grid_size - scale - 2), (4 * scale, scale)]))
    samples["letter_C_shifted"] = ("C", shift_matrix(templates["C"], dx=scale, dy=0))
    samples["letter_E_noisy"] = ("E", add_sparse_noise(templates["E"], [(0, scale), (grid_size - 1, 5 * scale)]))
    samples["letter_H_shifted"] = ("H", shift_matrix(templates["H"], dx=0, dy=scale))
    samples["letter_K_noisy"] = ("K", add_sparse_noise(templates["K"], [(2 * scale, 5 * scale), (5 * scale, 3 * scale)]))
    samples["letter_M_noisy"] = ("M", add_sparse_noise(templates["M"], [(scale, 2 * scale), (grid_size - scale - 2, 5 * scale)]))
    samples["letter_N_shifted"] = ("N", shift_matrix(templates["N"], dx=-scale, dy=0))
    samples["letter_R_noisy"] = ("R", add_sparse_noise(templates["R"], [(3 * scale, 4 * scale), (6 * scale, 2 * scale)]))
    samples["letter_X_shifted"] = ("X", shift_matrix(templates["X"], dx=0, dy=-scale))
    samples["letter_Y_noisy"] = ("Y", add_sparse_noise(templates["Y"], [(scale, 2 * scale), (6 * scale, 4 * scale)]))
    samples["letter_Z_shifted"] = ("Z", shift_matrix(templates["Z"], dx=scale, dy=0))
    return samples

