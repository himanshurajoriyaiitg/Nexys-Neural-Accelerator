from __future__ import annotations

import pickle
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from sklearn.datasets import load_digits
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

from digit_templates import add_sparse_noise, get_font_candidates, render_label_template, shift_matrix, thicken_matrix
from handwritten_digit_pipeline import (
    GRID_SIZE,
    SAMPLE_DIR,
    discover_local_digit_samples,
    discover_local_letter_samples,
    extract_features,
    preprocess_handwritten_image,
)


MODEL_VERSION = 3
MODEL_DIR = Path(__file__).resolve().parents[1] / "build"
MODEL_KIND_CNN = "cnn_int8"
MODEL_KIND_DIGIT_LINEAR = "digit_feature_linear"

DIGIT_LABELS = [str(i) for i in range(10)]
LETTER_LABELS = [chr(code) for code in range(ord("A"), ord("Z") + 1)]
ALNUM_LABELS = DIGIT_LABELS + LETTER_LABELS

CONV1_KERNELS = np.array(
    [
        [[1, 0, -1], [1, 0, -1], [1, 0, -1]],
        [[1, 1, 1], [0, 0, 0], [-1, -1, -1]],
        [[0, 1, 0], [1, -4, 1], [0, 1, 0]],
        [[1, 0, 0], [0, -1, 0], [0, 0, 1]],
        [[0, 0, 1], [0, -1, 0], [1, 0, 0]],
        [[1, 1, 0], [1, 0, -1], [0, -1, -1]],
        [[0, 1, 1], [-1, 0, 1], [-1, -1, 0]],
        [[1, 1, 1], [1, -8, 1], [1, 1, 1]],
    ],
    dtype=np.int8,
)

_conv2_rng = np.random.default_rng(1)
CONV2_KERNELS = _conv2_rng.integers(-2, 3, size=(16, 8, 3, 3), dtype=np.int8)
CONV1_BIAS = np.zeros((8,), dtype=np.int32)
CONV2_BIAS = np.zeros((16,), dtype=np.int32)


@dataclass
class FpgaCnnModel:
    charset: str
    model_kind: str
    labels: list[str]
    conv1_kernels: np.ndarray
    conv1_bias: np.ndarray
    conv2_kernels: np.ndarray
    conv2_bias: np.ndarray
    fc_weights: np.ndarray
    fc_bias: np.ndarray
    train_accuracy: float
    local_accuracy: float | None


def labels_for_charset(charset: str) -> list[str]:
    if charset == "digits":
        return DIGIT_LABELS
    if charset == "letters":
        return LETTER_LABELS
    if charset == "alnum":
        return ALNUM_LABELS
    raise ValueError(f"Unsupported charset: {charset}")


def round_clip_int8(values: np.ndarray) -> np.ndarray:
    return np.clip(np.rint(np.asarray(values, dtype=np.float32)), -128, 127).astype(np.int8)


def quantize_int8(values: np.ndarray, target_peak: float = 63.0) -> np.ndarray:
    values = np.asarray(values, dtype=np.float32)
    peak = float(np.max(np.abs(values)))
    scale = max(1.0, peak / target_peak)
    return np.clip(np.round(values / scale), -128, 127).astype(np.int8)


def relu(values: np.ndarray) -> np.ndarray:
    return np.maximum(values, 0)


def pool2(values: np.ndarray) -> np.ndarray:
    channels, height, width = values.shape
    return values.reshape(channels, height // 2, 2, width // 2, 2).max(axis=(2, 4))


def conv_same(input_maps: np.ndarray, kernels: np.ndarray) -> np.ndarray:
    if input_maps.ndim == 2:
        input_maps = input_maps[None, :, :]
    input_maps = np.asarray(input_maps, dtype=np.int32)
    kernels = np.asarray(kernels, dtype=np.int32)

    in_channels, height, width = input_maps.shape
    out_channels = kernels.shape[0]
    kernel_h = kernels.shape[-2]
    kernel_w = kernels.shape[-1]
    pad_h = kernel_h // 2
    pad_w = kernel_w // 2

    padded = np.pad(input_maps, ((0, 0), (pad_h, pad_h), (pad_w, pad_w)), mode="constant")
    outputs = np.zeros((out_channels, height, width), dtype=np.int32)

    for out_ch in range(out_channels):
        for row in range(height):
            for col in range(width):
                patch = padded[:, row : row + kernel_h, col : col + kernel_w]
                outputs[out_ch, row, col] = int(np.sum(patch * kernels[out_ch]))

    return outputs


def forward_feature_stack(image: np.ndarray) -> np.ndarray:
    raw = quantize_int8(image, target_peak=16.0)
    x0 = raw.astype(np.int32)
    conv1 = conv_same(x0, CONV1_KERNELS[:, None, :, :]) + CONV1_BIAS[:, None, None]
    conv1_q = quantize_int8(conv1).astype(np.int32)
    pool1 = pool2(relu(conv1_q))
    quant1 = quantize_int8(pool1)
    quant1_i32 = quant1.astype(np.int32)
    conv2 = conv_same(quant1_i32, CONV2_KERNELS) + CONV2_BIAS[:, None, None]
    conv2_q = quantize_int8(conv2).astype(np.int32)
    pool2_maps = pool2(relu(conv2_q))
    quant2 = quantize_int8(pool2_maps)
    return np.concatenate([raw.reshape(-1), quant1.reshape(-1), quant2.reshape(-1)]).astype(np.int8)


def quantize_digit_feature_vector(image: np.ndarray) -> np.ndarray:
    features = extract_features(np.asarray(image, dtype=np.float32)[None, :, :])[0]
    return round_clip_int8(features)


def _normalize_binary_template(matrix: np.ndarray) -> np.ndarray:
    fg = np.asarray(matrix) > 0
    coords = np.argwhere(fg)
    if coords.size == 0:
        return np.zeros((GRID_SIZE, GRID_SIZE), dtype=np.float32)

    top, left = coords.min(axis=0)
    bottom, right = coords.max(axis=0)
    crop = fg[top : bottom + 1, left : right + 1].astype(np.float32) * 255.0
    bbox_h, bbox_w = crop.shape
    pad = 2
    square_size = max(bbox_h, bbox_w) + (2 * pad)
    square = np.zeros((square_size, square_size), dtype=np.float32)
    row_offset = (square_size - bbox_h) // 2
    col_offset = (square_size - bbox_w) // 2
    square[row_offset : row_offset + bbox_h, col_offset : col_offset + bbox_w] = crop

    rows = np.linspace(0, square.shape[0], GRID_SIZE + 1).astype(int)
    cols = np.linspace(0, square.shape[1], GRID_SIZE + 1).astype(int)
    out = np.zeros((GRID_SIZE, GRID_SIZE), dtype=np.float32)
    for r in range(GRID_SIZE):
        for c in range(GRID_SIZE):
            block = square[rows[r] : rows[r + 1], cols[c] : cols[c + 1]]
            out[r, c] = float(block.mean()) if block.size else 0.0
    out -= out.min()
    if out.max() > 0:
        out *= 16.0 / out.max()
    return out.astype(np.float32)


def load_local_samples(charset: str) -> tuple[np.ndarray, np.ndarray]:
    images: list[np.ndarray] = []
    labels: list[str] = []

    sources: dict[str, str] = {}
    if charset in {"digits", "alnum"}:
        sources.update({filename: str(label) for filename, label in discover_local_digit_samples().items()})
    if charset in {"letters", "alnum"}:
        sources.update(discover_local_letter_samples())

    allowed = set(labels_for_charset(charset))
    for filename, label in sources.items():
        if label not in allowed:
            continue
        sample_path = SAMPLE_DIR / filename
        if not sample_path.exists():
            continue
        images.append(preprocess_handwritten_image(sample_path))
        labels.append(label)

    if not images:
        return np.zeros((0, GRID_SIZE, GRID_SIZE), dtype=np.float32), np.zeros((0,), dtype=object)
    return np.stack(images).astype(np.float32), np.array(labels, dtype=object)


def generate_letter_synthetic_dataset() -> tuple[np.ndarray, np.ndarray]:
    images: list[np.ndarray] = []
    labels: list[str] = []
    fonts = [path for path in get_font_candidates() if path.exists()][:2] or [None]
    for label in LETTER_LABELS:
        for font_path in fonts:
            for scale in (0.78, 0.88, 0.98):
                base = render_label_template(label, 32, preferred_font=font_path, font_scale=scale)
                variants = [
                    base,
                    shift_matrix(base, dx=1, dy=0),
                    shift_matrix(base, dx=-1, dy=0),
                    shift_matrix(base, dx=0, dy=1),
                    shift_matrix(base, dx=0, dy=-1),
                    thicken_matrix(base),
                    add_sparse_noise(base, [(4, 4), (10, 18), (24, 12)]),
                ]
                for variant in variants:
                    images.append(_normalize_binary_template(variant))
                    labels.append(label)
    return np.stack(images).astype(np.float32), np.array(labels, dtype=object)


def load_training_dataset(charset: str) -> tuple[np.ndarray, np.ndarray]:
    images: list[np.ndarray] = []
    labels: list[np.ndarray] = []

    if charset in {"digits", "alnum"}:
        digit_images = load_digits().images.astype(np.float32)
        digit_labels = np.array([str(value) for value in load_digits().target], dtype=object)
        images.append(digit_images)
        labels.append(digit_labels)

    if charset in {"letters", "alnum"}:
        letter_images, letter_labels = generate_letter_synthetic_dataset()
        images.append(letter_images)
        labels.append(letter_labels)

    local_images, local_labels = load_local_samples(charset)
    if len(local_images) > 0:
        repeat_count = 20 if charset == "digits" else 10
        images.append(np.repeat(local_images, repeat_count, axis=0))
        labels.append(np.repeat(local_labels, repeat_count, axis=0))

    return np.concatenate(images, axis=0), np.concatenate(labels, axis=0)


def train_digit_linear_model() -> FpgaCnnModel:
    images, labels = load_training_dataset("digits")
    features = round_clip_int8(extract_features(images))

    classifier = LogisticRegression(max_iter=10000, C=3.0, random_state=42)
    classifier.fit(features.astype(np.float32), labels)

    quantization_peaks = (63.0, 95.0, 127.0)
    best_weights: np.ndarray | None = None
    best_bias: np.ndarray | None = None
    best_train_accuracy = -1.0
    best_local_accuracy = -1.0

    local_images, local_labels = load_local_samples("digits")
    local_features = round_clip_int8(extract_features(local_images)) if len(local_images) > 0 else None

    for peak in quantization_peaks:
        weight_scale = float(np.max(np.abs(classifier.coef_))) / peak if np.max(np.abs(classifier.coef_)) > 0 else 1.0
        fc_weights = np.clip(np.round(classifier.coef_ / weight_scale), -127, 127).astype(np.int8)
        fc_bias = np.round(classifier.intercept_ / weight_scale).astype(np.int32)

        train_logits = features.astype(np.int32) @ fc_weights.T.astype(np.int32) + fc_bias
        train_predictions = np.asarray(classifier.classes_)[np.argmax(train_logits, axis=1)]
        train_accuracy = float(np.mean(train_predictions == labels))

        if local_features is not None:
            local_logits = local_features.astype(np.int32) @ fc_weights.T.astype(np.int32) + fc_bias
            local_predictions = np.asarray(classifier.classes_)[np.argmax(local_logits, axis=1)]
            local_accuracy = float(np.mean(local_predictions == local_labels))
        else:
            local_accuracy = train_accuracy

        if (local_accuracy > best_local_accuracy) or (
            local_accuracy == best_local_accuracy and train_accuracy > best_train_accuracy
        ):
            best_local_accuracy = local_accuracy
            best_train_accuracy = train_accuracy
            best_weights = fc_weights
            best_bias = fc_bias

    assert best_weights is not None
    assert best_bias is not None
    return FpgaCnnModel(
        charset="digits",
        model_kind=MODEL_KIND_DIGIT_LINEAR,
        labels=[str(item) for item in classifier.classes_],
        conv1_kernels=np.zeros((0,), dtype=np.int8),
        conv1_bias=np.zeros((0,), dtype=np.int32),
        conv2_kernels=np.zeros((0,), dtype=np.int8),
        conv2_bias=np.zeros((0,), dtype=np.int32),
        fc_weights=best_weights.copy(),
        fc_bias=best_bias.copy(),
        train_accuracy=best_train_accuracy,
        local_accuracy=(best_local_accuracy if len(local_images) > 0 else None),
    )


def train_cnn_model(charset: str) -> FpgaCnnModel:
    images, labels = load_training_dataset(charset)
    features = np.stack([forward_feature_stack(image) for image in images]).astype(np.float32)

    classifier = make_pipeline(
        StandardScaler(),
        LogisticRegression(max_iter=6000, C=3.0, random_state=42),
    )
    classifier.fit(features, labels)

    scaler = classifier.named_steps["standardscaler"]
    logistic = classifier.named_steps["logisticregression"]

    folded_weights = logistic.coef_ / scaler.scale_
    folded_bias = logistic.intercept_ - np.sum((logistic.coef_ * scaler.mean_) / scaler.scale_, axis=1)

    weight_scale = float(np.max(np.abs(folded_weights))) / 127.0 if np.max(np.abs(folded_weights)) > 0 else 1.0
    fc_weights = np.clip(np.round(folded_weights / weight_scale), -128, 127).astype(np.int8)
    fc_bias = np.round(folded_bias / weight_scale).astype(np.int32)

    quant_logits = features.astype(np.int32) @ fc_weights.T.astype(np.int32) + fc_bias
    train_predictions = np.asarray(logistic.classes_)[np.argmax(quant_logits, axis=1)]
    train_accuracy = float(np.mean(train_predictions == labels))

    local_images, local_labels = load_local_samples(charset)
    local_accuracy = None
    if len(local_images) > 0:
        local_features = np.stack([forward_feature_stack(image) for image in local_images]).astype(np.int32)
        local_logits = local_features @ fc_weights.T.astype(np.int32) + fc_bias
        local_predictions = np.asarray(logistic.classes_)[np.argmax(local_logits, axis=1)]
        local_accuracy = float(np.mean(local_predictions == local_labels))

    return FpgaCnnModel(
        charset=charset,
        model_kind=MODEL_KIND_CNN,
        labels=[str(item) for item in logistic.classes_],
        conv1_kernels=CONV1_KERNELS.copy(),
        conv1_bias=CONV1_BIAS.copy(),
        conv2_kernels=CONV2_KERNELS.copy(),
        conv2_bias=CONV2_BIAS.copy(),
        fc_weights=fc_weights.copy(),
        fc_bias=fc_bias.copy(),
        train_accuracy=train_accuracy,
        local_accuracy=local_accuracy,
    )


def train_model(charset: str) -> FpgaCnnModel:
    if charset == "digits":
        return train_digit_linear_model()
    return train_cnn_model(charset)


def save_model(model: FpgaCnnModel) -> None:
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    model_path = MODEL_DIR / f"fpga_cnn_model_{model.charset}.pkl"
    payload = {
        "version": MODEL_VERSION,
        "charset": model.charset,
        "model_kind": model.model_kind,
        "labels": model.labels,
        "conv1_kernels": model.conv1_kernels,
        "conv1_bias": model.conv1_bias,
        "conv2_kernels": model.conv2_kernels,
        "conv2_bias": model.conv2_bias,
        "fc_weights": model.fc_weights,
        "fc_bias": model.fc_bias,
        "train_accuracy": model.train_accuracy,
        "local_accuracy": model.local_accuracy,
    }
    with model_path.open("wb") as handle:
        pickle.dump(payload, handle)


def load_or_train_model(charset: str, force_retrain: bool = False) -> FpgaCnnModel:
    model_path = MODEL_DIR / f"fpga_cnn_model_{charset}.pkl"
    if not force_retrain and model_path.exists():
        with model_path.open("rb") as handle:
            payload = pickle.load(handle)
        if payload.get("version") == MODEL_VERSION and payload.get("charset") == charset:
            return FpgaCnnModel(
                charset=payload["charset"],
                model_kind=str(payload.get("model_kind", MODEL_KIND_CNN)),
                labels=list(payload["labels"]),
                conv1_kernels=np.asarray(payload["conv1_kernels"], dtype=np.int8),
                conv1_bias=np.asarray(payload["conv1_bias"], dtype=np.int32),
                conv2_kernels=np.asarray(payload["conv2_kernels"], dtype=np.int8),
                conv2_bias=np.asarray(payload["conv2_bias"], dtype=np.int32),
                fc_weights=np.asarray(payload["fc_weights"], dtype=np.int8),
                fc_bias=np.asarray(payload["fc_bias"], dtype=np.int32),
                train_accuracy=float(payload["train_accuracy"]),
                local_accuracy=(float(payload["local_accuracy"]) if payload["local_accuracy"] is not None else None),
            )

    model = train_model(charset)
    save_model(model)
    return model


def software_predict_logits(image: np.ndarray, model: FpgaCnnModel) -> np.ndarray:
    if model.model_kind == MODEL_KIND_DIGIT_LINEAR:
        features = quantize_digit_feature_vector(image).astype(np.int32)
        return features @ model.fc_weights.T.astype(np.int32) + model.fc_bias
    features = forward_feature_stack(image).astype(np.int32)
    return features @ model.fc_weights.T.astype(np.int32) + model.fc_bias
