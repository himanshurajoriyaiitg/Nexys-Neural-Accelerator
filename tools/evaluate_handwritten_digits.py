#!/usr/bin/env python3
from __future__ import annotations

import argparse
import gzip
import struct
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from sklearn.datasets import load_digits
from handwritten_digit_pipeline import (
    GRID_SIZE,
    extract_features,
    load_or_train_model,
)


@dataclass
class EvaluationResult:
    label: int
    total: int
    correct: int
    avg_true_prob: float
    avg_pred_prob: float


def downsample_28x28_to_8x8(image: np.ndarray) -> np.ndarray:
    image = np.asarray(image, dtype=np.float32)
    if image.shape != (28, 28):
        raise ValueError(f"Expected 28x28 image, got {image.shape}.")

    trimmed = image[2:26, 2:26]
    pooled = trimmed.reshape(8, 3, 8, 3).mean(axis=(1, 3))
    pooled -= pooled.min()
    if pooled.max() > 0:
        pooled *= 16.0 / pooled.max()
    return pooled.astype(np.float32)


def load_idx_images(path: Path) -> np.ndarray:
    with gzip.open(path, "rb") as handle:
        magic, count, rows, cols = struct.unpack(">IIII", handle.read(16))
        if magic != 2051:
            raise SystemExit(f"Unexpected image magic number in {path}: {magic}")
        data = np.frombuffer(handle.read(), dtype=np.uint8)
    return data.reshape(count, rows, cols)


def load_idx_labels(path: Path) -> np.ndarray:
    with gzip.open(path, "rb") as handle:
        magic, count = struct.unpack(">II", handle.read(8))
        if magic != 2049:
            raise SystemExit(f"Unexpected label magic number in {path}: {magic}")
        data = np.frombuffer(handle.read(), dtype=np.uint8)
    if len(data) != count:
        raise SystemExit(f"Label count mismatch in {path}: header={count}, bytes={len(data)}")
    return data


def load_sklearn_corpus(seed: int) -> tuple[np.ndarray, np.ndarray]:
    digits = load_digits()
    images = digits.images.astype(np.float32)
    labels = digits.target.astype(np.int64)
    rng = np.random.default_rng(seed)
    order = rng.permutation(len(images))
    return images[order], labels[order]


def load_mnist_local(image_path: Path, label_path: Path, seed: int) -> tuple[np.ndarray, np.ndarray]:
    images_28 = load_idx_images(image_path)
    labels = load_idx_labels(label_path).astype(np.int64)
    if len(images_28) != len(labels):
        raise SystemExit("MNIST image/label count mismatch.")
    images_8 = np.stack([downsample_28x28_to_8x8(image) for image in images_28]).astype(np.float32)
    rng = np.random.default_rng(seed)
    order = rng.permutation(len(images_8))
    return images_8[order], labels[order]


def sample_dataset(images: np.ndarray, labels: np.ndarray, sample_count: int, seed: int) -> tuple[np.ndarray, np.ndarray]:
    if sample_count >= len(images):
        return images, labels
    rng = np.random.default_rng(seed)
    indices = rng.choice(len(images), size=sample_count, replace=False)
    return images[indices], labels[indices]


def evaluate(images: np.ndarray, labels: np.ndarray) -> tuple[list[EvaluationResult], float]:
    payload = load_or_train_model(force_retrain=False)
    classifier = payload["classifier"]
    probabilities = classifier.predict_proba(extract_features(images))
    predictions = classifier.classes_[np.argmax(probabilities, axis=1)]
    overall_accuracy = float(np.mean(predictions == labels))

    results: list[EvaluationResult] = []
    for label in range(10):
        mask = labels == label
        label_probs = probabilities[mask]
        label_preds = predictions[mask]
        label_true = labels[mask]
        if len(label_true) == 0:
            results.append(EvaluationResult(label=label, total=0, correct=0, avg_true_prob=0.0, avg_pred_prob=0.0))
            continue

        class_index = int(np.where(classifier.classes_ == label)[0][0])
        avg_true_prob = float(np.mean(label_probs[:, class_index]))
        pred_conf = label_probs[np.arange(len(label_probs)), np.argmax(label_probs, axis=1)]
        avg_pred_prob = float(np.mean(pred_conf))
        correct = int(np.sum(label_preds == label_true))
        results.append(
            EvaluationResult(
                label=label,
                total=int(len(label_true)),
                correct=correct,
                avg_true_prob=avg_true_prob,
                avg_pred_prob=avg_pred_prob,
            )
        )
    return results, overall_accuracy


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Evaluate the handwritten-digit pipeline on 1000 random samples. "
            "Supports sklearn digits out of the box and local MNIST IDX gzip files."
        )
    )
    parser.add_argument("--dataset", choices=["sklearn", "mnist-local"], default="sklearn")
    parser.add_argument("--samples", type=int, default=1000)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--mnist-images", type=Path, help="Path to MNIST images IDX gzip, e.g. t10k-images-idx3-ubyte.gz")
    parser.add_argument("--mnist-labels", type=Path, help="Path to MNIST labels IDX gzip, e.g. t10k-labels-idx1-ubyte.gz")
    args = parser.parse_args()

    if args.dataset == "mnist-local":
        if args.mnist_images is None or args.mnist_labels is None:
            raise SystemExit("--mnist-images and --mnist-labels are required for --dataset mnist-local.")
        images, labels = load_mnist_local(args.mnist_images, args.mnist_labels, args.seed)
    else:
        images, labels = load_sklearn_corpus(args.seed)

    images, labels = sample_dataset(images, labels, args.samples, args.seed)
    results, overall_accuracy = evaluate(images, labels)

    print(f"Dataset          : {args.dataset}")
    print(f"Grid size        : {GRID_SIZE}x{GRID_SIZE}")
    print(f"Sample count     : {len(labels)}")
    print(f"Overall accuracy : {overall_accuracy:.6f}")
    print()
    print("Per-digit summary:")
    print("digit total correct accuracy avg_true_prob avg_pred_prob")
    for item in results:
        accuracy = (item.correct / item.total) if item.total else 0.0
        print(
            f"{item.label:>5} {item.total:>5} {item.correct:>7} "
            f"{accuracy:>8.6f} {item.avg_true_prob:>13.6f} {item.avg_pred_prob:>13.6f}"
        )


if __name__ == "__main__":
    main()
