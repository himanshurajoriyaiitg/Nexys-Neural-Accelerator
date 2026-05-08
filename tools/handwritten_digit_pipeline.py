from __future__ import annotations

import math
import pickle
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps
from sklearn.datasets import load_digits
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import train_test_split
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler


GRID_SIZE = 8
MODEL_VERSION = 3
MODEL_PATH = Path(__file__).resolve().parents[1] / "build" / "handwritten_digit_model.pkl"
SAMPLE_DIR = Path(__file__).resolve().parents[1] / "samples" / "recognizer"
DIGIT_NAME_TO_LABEL = {
    "zero": 0,
    "one": 1,
    "two": 2,
    "three": 3,
    "four": 4,
    "five": 5,
    "six": 6,
    "seven": 7,
    "eight": 8,
    "nine": 9,
}

KERNELS_STAGE1 = np.array(
    [
        [[1, 0, -1], [2, 0, -2], [1, 0, -1]],
        [[1, 2, 1], [0, 0, 0], [-1, -2, -1]],
        [[2, -1, -1], [-1, 2, -1], [-1, -1, 2]],
        [[-1, -1, 2], [-1, 2, -1], [2, -1, -1]],
        [[0, -1, 0], [-1, 4, -1], [0, -1, 0]],
        [[-1, -1, -1], [-1, 8, -1], [-1, -1, -1]],
        [[0, 1, 0], [1, -4, 1], [0, 1, 0]],
        [[1, 1, 1], [1, 1, 1], [1, 1, 1]],
    ],
    dtype=np.float32,
)

KERNELS_STAGE2 = np.array(
    [
        [[1, 0, -1], [1, 0, -1], [1, 0, -1]],
        [[1, 1, 1], [0, 0, 0], [-1, -1, -1]],
        [[0, 1, 0], [1, -4, 1], [0, 1, 0]],
        [[-1, 0, 1], [0, 0, 0], [1, 0, -1]],
        [[1, 0, 1], [0, -4, 0], [1, 0, 1]],
        [[-1, -1, -1], [-1, 8, -1], [-1, -1, -1]],
    ],
    dtype=np.float32,
)


@dataclass
class HandwrittenPrediction:
    predicted_label: str
    probabilities: dict[str, float]
    normalized_image: np.ndarray
    conv1: np.ndarray
    pool1: np.ndarray
    conv2: np.ndarray
    pool2: np.ndarray


def _softmax(values: np.ndarray) -> np.ndarray:
    shifted = values - np.max(values)
    exp_values = np.exp(shifted)
    return exp_values / np.sum(exp_values)


def _relu(values: np.ndarray) -> np.ndarray:
    return np.maximum(values, 0.0)


def _max_pool_2x2(values: np.ndarray) -> np.ndarray:
    n, c, h, w = values.shape
    h_even = (h // 2) * 2
    w_even = (w // 2) * 2
    trimmed = values[:, :, :h_even, :w_even]
    reshaped = trimmed.reshape(n, c, h_even // 2, 2, w_even // 2, 2)
    return reshaped.max(axis=(3, 5))


def _conv_same(inputs: np.ndarray, kernels: np.ndarray) -> np.ndarray:
    n, channels, height, width = inputs.shape
    filters = kernels.shape[0]
    outputs = np.zeros((n, channels * filters, height, width), dtype=np.float32)
    padded = np.pad(inputs, ((0, 0), (0, 0), (1, 1), (1, 1)), mode="constant")

    for row in range(height):
        for col in range(width):
            patch = padded[:, :, row : row + 3, col : col + 3]
            response = np.tensordot(patch, kernels, axes=([2, 3], [1, 2]))
            outputs[:, :, row, col] = response.reshape(n, channels * filters)
    return outputs


def _extract_feature_stages(images: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    normalized = images.astype(np.float32) / 16.0
    x0 = normalized[:, None, :, :]
    conv1 = _relu(_conv_same(x0, KERNELS_STAGE1))
    pool1 = _max_pool_2x2(conv1)
    conv2 = _relu(_conv_same(pool1, KERNELS_STAGE2))
    pool2 = _max_pool_2x2(conv2)
    return conv1, pool1, conv2, pool2


def extract_features(images: np.ndarray) -> np.ndarray:
    conv1, pool1, conv2, pool2 = _extract_feature_stages(images)
    raw = images.astype(np.float32) / 16.0
    return np.concatenate(
        [
            pool2.reshape(len(images), -1),
            pool1.mean(axis=(2, 3)),
            pool2.mean(axis=(2, 3)),
            raw.reshape(len(images), -1),
        ],
        axis=1,
    )


def _otsu_threshold(image: np.ndarray) -> int:
    hist = np.bincount(image.reshape(-1), minlength=256).astype(np.float64)
    total = hist.sum()
    weighted_total = np.dot(np.arange(256, dtype=np.float64), hist)

    best_threshold = 0
    best_variance = -1.0
    weight_bg = 0.0
    sum_bg = 0.0

    for threshold in range(256):
        weight_bg += hist[threshold]
        if weight_bg == 0:
            continue
        weight_fg = total - weight_bg
        if weight_fg == 0:
            break
        sum_bg += threshold * hist[threshold]
        mean_bg = sum_bg / weight_bg
        mean_fg = (weighted_total - sum_bg) / weight_fg
        variance = weight_bg * weight_fg * (mean_bg - mean_fg) ** 2
        if variance > best_variance:
            best_variance = variance
            best_threshold = threshold

    return best_threshold


def preprocess_handwritten_array(
    image_array: np.ndarray,
    invert: bool = False,
    threshold: int | None = None,
    pad: int = 2,
    target_size: int = GRID_SIZE,
) -> np.ndarray:
    image = Image.fromarray(np.asarray(image_array, dtype=np.uint8), mode="L")
    image = ImageOps.autocontrast(image)
    image_np = np.array(image, dtype=np.uint8)

    if invert:
        image_np = 255 - image_np

    used_threshold = threshold if threshold is not None else _otsu_threshold(image_np)
    bright_fg = image_np >= used_threshold
    dark_fg = image_np <= used_threshold
    foreground_is_bright = int(bright_fg.sum()) <= int(dark_fg.sum())
    foreground = bright_fg if foreground_is_bright else dark_fg

    coords = np.argwhere(foreground)
    if coords.size == 0:
        raise SystemExit("Could not find a foreground digit region in the input image.")

    top, left = coords.min(axis=0)
    bottom, right = coords.max(axis=0)

    crop = image_np[top : bottom + 1, left : right + 1].astype(np.float32)
    if not foreground_is_bright:
        crop = 255.0 - crop

    crop -= crop.min()
    if crop.max() > 0:
        crop *= 255.0 / crop.max()

    bbox_h, bbox_w = crop.shape
    square_size = max(bbox_h, bbox_w) + (2 * pad)
    square = np.zeros((square_size, square_size), dtype=np.float32)
    row_offset = (square_size - bbox_h) // 2
    col_offset = (square_size - bbox_w) // 2
    square[row_offset : row_offset + bbox_h, col_offset : col_offset + bbox_w] = crop

    resized = Image.fromarray(square.astype(np.uint8), mode="L").resize((target_size, target_size), Image.Resampling.BILINEAR)
    resized_np = np.array(resized, dtype=np.float32)
    resized_np -= resized_np.min()
    if resized_np.max() > 0:
        resized_np *= 16.0 / resized_np.max()
    return resized_np.astype(np.float32)


def preprocess_handwritten_image(
    path: Path,
    invert: bool = False,
    threshold: int | None = None,
    pad: int = 2,
) -> np.ndarray:
    image = Image.open(path).convert("L")
    image_np = np.array(image, dtype=np.uint8)
    try:
        return preprocess_handwritten_array(
            image_np,
            invert=invert,
            threshold=threshold,
            pad=pad,
            target_size=GRID_SIZE,
        )
    except SystemExit as exc:
        raise SystemExit(f"Could not preprocess {path}: {exc}") from exc


def preprocess_binary_matrix(matrix: np.ndarray) -> np.ndarray:
    matrix = np.asarray(matrix, dtype=np.float32)
    positive = matrix > 0
    return np.where(positive, 16.0, 0.0).astype(np.float32)


def digit_label_from_stem(stem: str) -> int | None:
    normalized = stem.strip().lower()
    if normalized in DIGIT_NAME_TO_LABEL:
        return DIGIT_NAME_TO_LABEL[normalized]
    if len(normalized) == 1 and normalized.isdigit():
        return int(normalized)
    if normalized.isdigit() and len(set(normalized)) == 1:
        return int(normalized[0])
    return None


def letter_label_from_stem(stem: str) -> str | None:
    normalized = stem.strip()
    if len(normalized) == 1 and normalized.isalpha():
        return normalized.upper()
    return None


def discover_local_digit_samples(sample_dir: Path = SAMPLE_DIR) -> dict[str, int]:
    samples: dict[str, int] = {}
    for sample_path in sorted(sample_dir.glob("*.png")):
        label = digit_label_from_stem(sample_path.stem)
        if label is not None:
            samples[sample_path.name] = label
    return samples


def discover_local_letter_samples(sample_dir: Path = SAMPLE_DIR) -> dict[str, str]:
    samples: dict[str, str] = {}
    for sample_path in sorted(sample_dir.glob("*.png")):
        label = letter_label_from_stem(sample_path.stem)
        if label is not None:
            samples[sample_path.name] = label
    return samples


def load_reference_digit_samples() -> tuple[np.ndarray, np.ndarray]:
    images: list[np.ndarray] = []
    labels: list[int] = []

    for filename, label in discover_local_digit_samples().items():
        sample_path = SAMPLE_DIR / filename
        if not sample_path.exists():
            continue
        images.append(preprocess_handwritten_image(sample_path))
        labels.append(label)

    if not images:
        return np.zeros((0, GRID_SIZE, GRID_SIZE), dtype=np.float32), np.zeros((0,), dtype=np.int64)

    return np.stack(images).astype(np.float32), np.array(labels, dtype=np.int64)


def train_handwritten_model(random_state: int = 42) -> dict[str, object]:
    digits = load_digits()
    images = digits.images.astype(np.float32)
    labels = digits.target.astype(np.int64)
    features = extract_features(images)
    x_train, x_test, y_train, y_test = train_test_split(
        features,
        labels,
        test_size=0.2,
        random_state=random_state,
        stratify=labels,
    )

    reference_images, reference_labels = load_reference_digit_samples()
    if len(reference_images) > 0:
        reference_features = extract_features(reference_images)
        x_train = np.concatenate([x_train, reference_features], axis=0)
        y_train = np.concatenate([y_train, reference_labels], axis=0)

    classifier = make_pipeline(
        StandardScaler(),
        LogisticRegression(max_iter=3000, C=3.0, random_state=random_state),
    )
    classifier.fit(x_train, y_train)

    reference_accuracy = None
    if len(reference_images) > 0:
        reference_accuracy = float(classifier.score(extract_features(reference_images), reference_labels))

    payload: dict[str, object] = {
        "version": MODEL_VERSION,
        "classifier": classifier,
        "test_accuracy": float(classifier.score(x_test, y_test)),
        "train_accuracy": float(classifier.score(x_train, y_train)),
        "reference_accuracy": reference_accuracy,
        "grid_size": GRID_SIZE,
    }
    MODEL_PATH.parent.mkdir(parents=True, exist_ok=True)
    with MODEL_PATH.open("wb") as handle:
        pickle.dump(payload, handle)
    return payload


def load_or_train_model(force_retrain: bool = False) -> dict[str, object]:
    if not force_retrain and MODEL_PATH.exists():
        with MODEL_PATH.open("rb") as handle:
            payload = pickle.load(handle)
        if payload.get("version") == MODEL_VERSION:
            return payload
    return train_handwritten_model()


def run_self_test(force_retrain: bool = False) -> tuple[float, float]:
    payload = load_or_train_model(force_retrain=force_retrain)
    return float(payload["train_accuracy"]), float(payload["test_accuracy"])


def predict_digit(
    image: np.ndarray,
    force_retrain: bool = False,
) -> HandwrittenPrediction:
    normalized = np.asarray(image, dtype=np.float32)
    if normalized.shape != (GRID_SIZE, GRID_SIZE):
        raise ValueError(f"Expected an {GRID_SIZE}x{GRID_SIZE} image, got {normalized.shape}.")

    payload = load_or_train_model(force_retrain=force_retrain)
    classifier = payload["classifier"]
    feature_batch = extract_features(normalized[None, :, :])
    probabilities = classifier.predict_proba(feature_batch)[0]
    labels = [str(label) for label in classifier.classes_]
    probability_map = {label: float(prob) for label, prob in zip(labels, probabilities)}
    predicted_label = max(probability_map, key=probability_map.get)

    conv1, pool1, conv2, pool2 = _extract_feature_stages(normalized[None, :, :])
    return HandwrittenPrediction(
        predicted_label=predicted_label,
        probabilities=probability_map,
        normalized_image=normalized,
        conv1=conv1[0],
        pool1=pool1[0],
        conv2=conv2[0],
        pool2=pool2[0],
    )
