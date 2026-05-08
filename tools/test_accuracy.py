#!/usr/bin/env python3
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

from fpga_cnn_infer import SoftwareSquareBackend, run_fpga_cnn_backend
from fpga_cnn_model import load_or_train_model as load_cnn_model
from fpga_snn_infer import load_snn_model, preprocess_snn_image, run_fpga_snn_backend
from handwritten_digit_pipeline import (
    SAMPLE_DIR,
    discover_local_digit_samples,
    predict_digit,
    preprocess_handwritten_image,
)


REFERENCE_SAMPLE_DIR = Path("/tmp/InduwaraGunasena-SNN-FPGA/Python scripts/sample MNIST data")


@dataclass
class PredictionRecord:
    path: Path
    expected: str
    predicted: str
    confidence: float


def load_local_samples() -> list[tuple[Path, str]]:
    pairs: list[tuple[Path, str]] = []
    for filename, label in sorted(discover_local_digit_samples().items()):
        pairs.append((SAMPLE_DIR / filename, str(label)))
    return pairs


def load_reference_samples(reference_dir: Path) -> list[tuple[Path, str]]:
    if not reference_dir.exists():
        raise SystemExit(f"Reference sample directory not found: {reference_dir}")

    pairs: list[tuple[Path, str]] = []
    for sample_path in sorted(reference_dir.glob("*.png")):
        if sample_path.stem.isdigit() and len(sample_path.stem) == 1:
            pairs.append((sample_path, sample_path.stem))

    if not pairs:
        raise SystemExit(f"No digit PNG files found under {reference_dir}")
    return pairs


def load_samples(dataset: str, reference_dir: Path) -> list[tuple[Path, str]]:
    if dataset == "local":
        return load_local_samples()
    if dataset == "reference":
        return load_reference_samples(reference_dir)

    samples = load_local_samples()
    seen = {path.resolve() for path, _ in samples}
    for path, expected in load_reference_samples(reference_dir):
        resolved = path.resolve()
        if resolved not in seen:
            samples.append((path, expected))
    return samples


def evaluate_handwritten(
    samples: list[tuple[Path, str]],
    retrain_model: bool,
) -> list[PredictionRecord]:
    records: list[PredictionRecord] = []
    for path, expected in samples:
        normalized = preprocess_handwritten_image(path)
        prediction = predict_digit(normalized, force_retrain=retrain_model)
        confidence = float(max(prediction.probabilities.values()))
        records.append(
            PredictionRecord(
                path=path,
                expected=expected,
                predicted=prediction.predicted_label,
                confidence=confidence,
            )
        )
    return records


def evaluate_cnn(
    samples: list[tuple[Path, str]],
    retrain_model: bool,
) -> list[PredictionRecord]:
    backend = SoftwareSquareBackend()
    model = load_cnn_model("digits", force_retrain=retrain_model)
    records: list[PredictionRecord] = []
    for path, expected in samples:
        normalized = preprocess_handwritten_image(path)
        logits = run_fpga_cnn_backend(normalized, model, backend)
        shifted = logits - np.max(logits)
        exp_logits = np.exp(shifted)
        probabilities = exp_logits / np.sum(exp_logits)
        best_index = int(np.argmax(probabilities))
        records.append(
            PredictionRecord(
                path=path,
                expected=expected,
                predicted=model.labels[best_index],
                confidence=float(probabilities[best_index]),
            )
        )
    return records


def evaluate_snn(samples: list[tuple[Path, str]]) -> list[PredictionRecord]:
    backend = SoftwareSquareBackend()
    model = load_snn_model()
    records: list[PredictionRecord] = []
    for path, expected in samples:
        image = np.array(Image.open(path).convert("L"), dtype=np.float32)
        normalized = preprocess_snn_image(image)
        result = run_fpga_snn_backend(normalized, model, backend)
        probabilities = np.asarray(result["probabilities"], dtype=np.float64)
        confidence = float(probabilities[int(result["prediction"])]) if probabilities.sum() > 0 else 0.0
        records.append(
            PredictionRecord(
                path=path,
                expected=expected,
                predicted=str(result["label"]),
                confidence=confidence,
            )
        )
    return records


def evaluate(
    model_name: str,
    samples: list[tuple[Path, str]],
    retrain_model: bool,
) -> list[PredictionRecord]:
    if model_name == "handwritten":
        return evaluate_handwritten(samples, retrain_model)
    if model_name == "cnn":
        return evaluate_cnn(samples, retrain_model)
    return evaluate_snn(samples)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Evaluate the repo's digit-recognition paths on the bundled recognizer samples "
            "or on the reference repo's MNIST PNG samples."
        )
    )
    parser.add_argument("--model", choices=["cnn", "handwritten", "snn"], default="cnn")
    parser.add_argument("--dataset", choices=["local", "reference", "all"], default="local")
    parser.add_argument("--reference-dir", type=Path, default=REFERENCE_SAMPLE_DIR)
    parser.add_argument("--retrain-model", action="store_true")
    parser.add_argument("--failures-only", action="store_true")
    args = parser.parse_args()

    samples = load_samples(args.dataset, args.reference_dir)
    records = evaluate(args.model, samples, args.retrain_model)

    correct = 0
    for record in records:
        is_correct = record.predicted == record.expected
        correct += int(is_correct)
        if args.failures_only and is_correct:
            continue
        status = "PASS" if is_correct else "FAIL"
        print(
            f"{status:4} expected={record.expected} predicted={record.predicted} "
            f"confidence={record.confidence:.4f} sample={record.path}"
        )

    accuracy = (correct / len(records)) if records else 0.0
    print()
    print(f"Model    : {args.model}")
    print(f"Dataset  : {args.dataset}")
    print(f"Samples  : {len(records)}")
    print(f"Accuracy : {correct}/{len(records)} = {accuracy:.6f}")


if __name__ == "__main__":
    main()
