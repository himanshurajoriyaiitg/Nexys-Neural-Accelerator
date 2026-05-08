from __future__ import annotations

import pickle
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

from digit_templates import (
    add_sparse_noise,
    get_font_candidates,
    render_label_template,
    shift_matrix,
    thicken_matrix,
)
from handwritten_digit_pipeline import (
    GRID_SIZE,
    SAMPLE_DIR,
    discover_local_letter_samples,
    extract_features,
    preprocess_handwritten_image,
)


MODEL_VERSION = 2
MODEL_PATH = Path(__file__).resolve().parents[1] / "build" / "handwritten_character_model.pkl"
LETTER_LABELS = [chr(code) for code in range(ord("A"), ord("Z") + 1)]
ALNUM_LABELS = [str(i) for i in range(10)] + LETTER_LABELS


@dataclass
class HandwrittenCharacterPrediction:
    predicted_label: str
    probabilities: dict[str, float]
    normalized_image: np.ndarray


def _labels_for_charset(charset: str) -> list[str]:
    if charset == "letters":
        return LETTER_LABELS
    if charset == "alnum":
        return ALNUM_LABELS
    raise ValueError(f"Unsupported charset for handwritten character pipeline: {charset}")


def _normalize_pm1_matrix(matrix: np.ndarray) -> np.ndarray:
    matrix = np.asarray(matrix, dtype=np.float32)
    fg = matrix > 0
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

    # Simple area-style shrink to 8x8 via block averaging.
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


def _generate_synthetic_samples(labels: list[str]) -> tuple[np.ndarray, np.ndarray]:
    samples: list[np.ndarray] = []
    targets: list[str] = []
    font_choices = [path for path in get_font_candidates() if path.exists()][:2] or [None]

    for label in labels:
        for font_path in font_choices:
            for font_scale in (0.80, 0.90, 1.00):
                base32 = render_label_template(label, 32, preferred_font=font_path, font_scale=font_scale)
                variants = [
                    base32,
                    shift_matrix(base32, dx=1, dy=0),
                    shift_matrix(base32, dx=-1, dy=0),
                    shift_matrix(base32, dx=0, dy=1),
                    shift_matrix(base32, dx=0, dy=-1),
                    thicken_matrix(base32),
                    add_sparse_noise(base32, [(4, 4), (12, 18), (22, 10)]),
                ]
                for variant in variants:
                    samples.append(_normalize_pm1_matrix(variant))
                    targets.append(label)

    return np.stack(samples).astype(np.float32), np.array(targets, dtype=object)


def _load_local_handwritten_letter_samples(labels: list[str]) -> tuple[np.ndarray, np.ndarray]:
    samples: list[np.ndarray] = []
    targets: list[str] = []
    allowed = set(labels)
    for filename, label in discover_local_letter_samples().items():
        if label not in allowed:
            continue
        sample_path = SAMPLE_DIR / filename
        if not sample_path.exists():
            continue
        samples.append(preprocess_handwritten_image(sample_path))
        targets.append(label)

    if not samples:
        return np.zeros((0, GRID_SIZE, GRID_SIZE), dtype=np.float32), np.zeros((0,), dtype=object)
    return np.stack(samples).astype(np.float32), np.array(targets, dtype=object)


def train_model(charset: str) -> dict[str, object]:
    labels = _labels_for_charset(charset)
    synth_images, synth_labels = _generate_synthetic_samples(labels)
    local_images, local_labels = _load_local_handwritten_letter_samples(labels)

    if len(local_images) > 0:
        train_images = np.concatenate([synth_images, local_images], axis=0)
        train_labels = np.concatenate([synth_labels, local_labels], axis=0)
    else:
        train_images = synth_images
        train_labels = synth_labels

    classifier = make_pipeline(
        StandardScaler(),
        LogisticRegression(max_iter=4000, C=4.0, random_state=42),
    )
    classifier.fit(extract_features(train_images), train_labels)

    payload: dict[str, object] = {
        "version": MODEL_VERSION,
        "charset": charset,
        "classifier": classifier,
        "train_accuracy": float(classifier.score(extract_features(train_images), train_labels)),
        "local_accuracy": (
            float(classifier.score(extract_features(local_images), local_labels))
            if len(local_images) > 0
            else None
        ),
    }
    MODEL_PATH.parent.mkdir(parents=True, exist_ok=True)
    with MODEL_PATH.open("wb") as handle:
        pickle.dump(payload, handle)
    return payload


def load_or_train_model(charset: str, force_retrain: bool = False) -> dict[str, object]:
    if not force_retrain and MODEL_PATH.exists():
        with MODEL_PATH.open("rb") as handle:
            payload = pickle.load(handle)
        if payload.get("version") == MODEL_VERSION and payload.get("charset") == charset:
            return payload
    return train_model(charset)


def run_self_test(charset: str, force_retrain: bool = False) -> tuple[float, float | None]:
    payload = load_or_train_model(charset=charset, force_retrain=force_retrain)
    return float(payload["train_accuracy"]), (
        float(payload["local_accuracy"]) if payload.get("local_accuracy") is not None else None
    )


def predict_character(
    image: np.ndarray,
    charset: str,
    force_retrain: bool = False,
) -> HandwrittenCharacterPrediction:
    normalized = np.asarray(image, dtype=np.float32)
    if normalized.shape != (GRID_SIZE, GRID_SIZE):
        raise ValueError(f"Expected an {GRID_SIZE}x{GRID_SIZE} image, got {normalized.shape}.")

    payload = load_or_train_model(charset=charset, force_retrain=force_retrain)
    classifier = payload["classifier"]
    feature_batch = extract_features(normalized[None, :, :])
    probabilities = classifier.predict_proba(feature_batch)[0]
    labels = [str(label) for label in classifier.classes_]
    probability_map = {label: float(prob) for label, prob in zip(labels, probabilities)}
    predicted_label = max(probability_map, key=probability_map.get)
    return HandwrittenCharacterPrediction(
        predicted_label=predicted_label,
        probabilities=probability_map,
        normalized_image=normalized,
    )
