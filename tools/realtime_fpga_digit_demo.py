#!/usr/bin/env python3
from __future__ import annotations

import argparse
import math
import threading
import time
import tkinter as tk
from dataclasses import dataclass

import numpy as np

from fpga_cnn_infer import FpgaSquareBackend, SoftwareSquareBackend, label_to_led_code, run_fpga_cnn_backend
from fpga_cnn_model import GRID_SIZE as CNN_GRID_SIZE, load_or_train_model
from fpga_snn_infer import load_snn_model, run_fpga_snn_backend, preprocess_snn_image, GRID_SIZE as SNN_GRID_SIZE
from handwritten_digit_pipeline import preprocess_handwritten_array


WORK_GRID_SIZE = 32
CELL_SIZE = 14
PADDING = 20
BRUSH_RADIUS = 2.2
DEFAULT_SEND_INTERVAL_S = 0.12
POLL_INTERVAL_MS = 50


@dataclass
class InferenceSummary:
    prediction: str
    confidence: float
    latency_ms: float
    fpga_cycles: int
    fpga_latency_ms: float | None
    accelerator_calls: int
    upload_bytes: int
    upload_commands: int
    normalized: np.ndarray


class RealTimeDigitDemo:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        if args.model == "snn":
            self.model = load_snn_model()
            self.grid_size = SNN_GRID_SIZE
            self.run_backend = run_fpga_snn_backend
        else:
            self.model = load_or_train_model("digits", force_retrain=args.retrain_model)
            self.grid_size = CNN_GRID_SIZE
            self.run_backend = run_fpga_cnn_backend
            
        if args.backend == "fpga":
            if not args.port:
                raise SystemExit("--port is required in FPGA mode.")
            self.backend = FpgaSquareBackend(args.port, args.baud)
        else:
            self.backend = SoftwareSquareBackend()

        self.root = tk.Tk()
        self.root.title("Nexys A7 Real-Time Digit Demo")
        self.root.protocol("WM_DELETE_WINDOW", self.close)

        self.canvas_size = (WORK_GRID_SIZE * CELL_SIZE) + (2 * PADDING)
        self.canvas = tk.Canvas(self.root, width=self.canvas_size, height=self.canvas_size, bg="white", highlightthickness=0)
        self.canvas.pack(padx=12, pady=(12, 8))

        self.info_frame = tk.Frame(self.root, padx=12, pady=4)
        self.info_frame.pack(fill="x")

        self.lbl_backend = tk.Label(self.info_frame, text=f"Backend: {args.backend} | Model: {args.model.upper()} ({self.grid_size}x{self.grid_size})", font=("Consolas", 11))
        self.lbl_backend.pack()

        self.lbl_status = tk.Label(self.info_frame, text="Draw a digit to start live recognition.", font=("Arial", 11), fg="#555555")
        self.lbl_status.pack()

        self.lbl_prediction = tk.Label(self.info_frame, text="Prediction: --", font=("Arial", 22, "bold"), fg="#1F4E79")
        self.lbl_prediction.pack(pady=(4, 0))

        self.lbl_latency = tk.Label(self.info_frame, text="Latency: --", font=("Consolas", 11), fg="#555555")
        self.lbl_latency.pack()

        self.lbl_metrics = tk.Label(self.info_frame, text="FPGA jobs: --", font=("Consolas", 10), fg="#666666")
        self.lbl_metrics.pack()

        self.button_frame = tk.Frame(self.root, padx=12, pady=10)
        self.button_frame.pack(fill="x")
        tk.Button(self.button_frame, text="Clear Grid", command=self.clear_grid, width=14).pack(side="left")

        self.work_grid = np.zeros((WORK_GRID_SIZE, WORK_GRID_SIZE), dtype=np.uint8)
        self.rects: list[list[int]] = []
        self._build_grid()

        self.dirty = False
        self.inflight = False
        self.closed = False
        self.last_submit_time = 0.0
        self.request_id = 0

        self.canvas.bind("<B1-Motion>", self.paint_brush)
        self.canvas.bind("<Button-1>", self.paint_brush)
        self.root.after(POLL_INTERVAL_MS, self._poll_for_inference)

    def _build_grid(self) -> None:
        for row in range(WORK_GRID_SIZE):
            row_rects: list[int] = []
            for col in range(WORK_GRID_SIZE):
                x0 = PADDING + (col * CELL_SIZE)
                y0 = PADDING + (row * CELL_SIZE)
                rect_id = self.canvas.create_rectangle(
                    x0,
                    y0,
                    x0 + CELL_SIZE,
                    y0 + CELL_SIZE,
                    fill="#ffffff",
                    outline="#d7d7d7",
                    width=1,
                )
                row_rects.append(rect_id)
            self.rects.append(row_rects)

    @staticmethod
    def _cell_color(value: int) -> str:
        shade = 255 - max(0, min(255, int(value)))
        return f"#{shade:02x}{shade:02x}{shade:02x}"

    def _update_cell(self, row: int, col: int, intensity: int) -> None:
        if not (0 <= row < WORK_GRID_SIZE and 0 <= col < WORK_GRID_SIZE):
            return
        new_value = max(0, min(255, int(self.work_grid[row, col]) + intensity))
        if new_value == int(self.work_grid[row, col]):
            return
        self.work_grid[row, col] = np.uint8(new_value)
        self.canvas.itemconfig(self.rects[row][col], fill=self._cell_color(new_value))
        self.dirty = True

    def paint_brush(self, event: tk.Event[tk.Misc]) -> None:
        col = (event.x - PADDING) // CELL_SIZE
        row = (event.y - PADDING) // CELL_SIZE
        radius = int(math.ceil(BRUSH_RADIUS))
        for d_row in range(-radius, radius + 1):
            for d_col in range(-radius, radius + 1):
                dist = math.sqrt((d_row * d_row) + (d_col * d_col))
                if dist <= BRUSH_RADIUS:
                    gain = int(255 * (1.0 - (dist / (BRUSH_RADIUS + 0.2))))
                    self._update_cell(row + d_row, col + d_col, gain)

    def clear_grid(self) -> None:
        self.request_id += 1
        self.dirty = False
        self.inflight = False
        self.work_grid.fill(0)
        for row in range(WORK_GRID_SIZE):
            for col in range(WORK_GRID_SIZE):
                self.canvas.itemconfig(self.rects[row][col], fill="#ffffff")
        self.lbl_status.config(text="Draw a digit to start live recognition.", fg="#555555")
        self.lbl_prediction.config(text="Prediction: --", fg="#1F4E79")
        self.lbl_latency.config(text="Latency: --")
        self.lbl_metrics.config(text="FPGA jobs: --")

    def _capture_normalized_image(self) -> np.ndarray | None:
        if int(self.work_grid.max()) == 0:
            return None
        
        if self.args.model == "snn":
            return preprocess_snn_image(self.work_grid)
            
        return preprocess_handwritten_array(
            self.work_grid,
            invert=False,
            threshold=None,
            pad=max(2, self.args.pad),
            target_size=self.grid_size,
        )

    def _poll_for_inference(self) -> None:
        if self.closed:
            return
        now = time.perf_counter()
        if self.dirty and not self.inflight and (now - self.last_submit_time) >= self.args.send_interval:
            normalized = self._capture_normalized_image()
            if normalized is not None:
                self.request_id += 1
                current_request = self.request_id
                self.dirty = False
                self.inflight = True
                self.last_submit_time = now
                status_text = (
                    "Running FPGA-backed inference..."
                    if self.args.backend == "fpga"
                    else "Running software inference..."
                )
                self.lbl_status.config(text=status_text, fg="#777777")
                self.lbl_prediction.config(text="Prediction: ...", fg="#777777")
                self.lbl_latency.config(text="Latency: ...")
                worker = threading.Thread(
                    target=self._run_inference_worker,
                    args=(current_request, normalized.copy()),
                    daemon=True,
                )
                worker.start()
        self.root.after(POLL_INTERVAL_MS, self._poll_for_inference)

    def _run_inference_worker(self, request_id: int, normalized: np.ndarray) -> None:
        try:
            self.backend.reset_metrics()
            start_time = time.perf_counter()
            native_board_display = self.args.backend == "fpga" and self.args.model == "snn"
            
            if self.args.model == "snn":
                res = self.run_backend(normalized, self.model, self.backend)
                prediction = res['label']
                confidence = float(np.max(res['probabilities']))
                elapsed_ms = res['latency_ms']
            else:
                logits = self.run_backend(normalized, self.model, self.backend)
                elapsed_ms = (time.perf_counter() - start_time) * 1000.0
                exp_logits = np.exp(logits - np.max(logits))
                probabilities = exp_logits / np.sum(exp_logits)
                best_index = int(np.argmax(probabilities))
                prediction = self.model.labels[best_index]
                confidence = float(probabilities[best_index])

            fpga_cycles = int(self.backend.metrics.total_cycle_count)
            fpga_latency_ms = None
            if fpga_cycles > 0:
                fpga_latency_ms = (fpga_cycles / float(self.args.fpga_clock_hz)) * 1000.0

            if self.args.backend == "fpga" and not self.args.no_board_display and not native_board_display:
                self.backend.set_led_code(label_to_led_code(prediction))

            summary = InferenceSummary(
                prediction=prediction,
                confidence=confidence,
                latency_ms=elapsed_ms,
                fpga_cycles=fpga_cycles,
                fpga_latency_ms=fpga_latency_ms,
                accelerator_calls=int(self.backend.metrics.accelerator_calls),
                upload_bytes=int(self.backend.metrics.matrix_upload_bytes),
                upload_commands=int(self.backend.metrics.matrix_upload_commands),
                normalized=normalized,
            )
            self.root.after(0, lambda: self._finish_inference(request_id, summary, None))
        except Exception as exc:  # pragma: no cover - GUI error path
            self.root.after(0, lambda: self._finish_inference(request_id, None, str(exc)))

    def _finish_inference(
        self,
        request_id: int,
        summary: InferenceSummary | None,
        error: str | None,
    ) -> None:
        if self.closed or request_id != self.request_id:
            return

        self.inflight = False
        if error is not None:
            self.lbl_status.config(text=f"Inference failed: {error}", fg="#AA0000")
            self.lbl_prediction.config(text="Prediction: error", fg="#AA0000")
            self.lbl_latency.config(text="Latency: --")
            self.lbl_metrics.config(text="FPGA jobs: --")
            return

        assert summary is not None
        self.lbl_status.config(text="Live recognition active.", fg="#2E6F40")
        self.lbl_prediction.config(
            text=f"Prediction: {summary.prediction} ({summary.confidence * 100.0:.1f}%)",
            fg="#1F4E79",
        )
        if summary.fpga_latency_ms is not None:
            self.lbl_latency.config(
                text=(
                    f"Latency: host {summary.latency_ms:.1f} ms | "
                    f"core {summary.fpga_latency_ms:.3f} ms ({summary.fpga_cycles} cycles)"
                )
            )
        else:
            self.lbl_latency.config(text=f"Latency: host {summary.latency_ms:.1f} ms")
        self.lbl_metrics.config(
            text=(
                f"FPGA jobs: {summary.accelerator_calls} | "
                f"upload: {summary.upload_bytes} bytes across {summary.upload_commands} commands"
            )
        )

    def run(self) -> None:
        self.root.mainloop()

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        try:
            if hasattr(self.backend, "close"):
                self.backend.close()
        finally:
            self.root.destroy()


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Real-time handwritten digit demo for the Nexys A7 flow. "
            "This mirrors the draw-and-classify loop of the reference SNN project, "
            "but keeps the computation on our faster FPGA-backed matmul pipeline."
        )
    )
    parser.add_argument("--model", choices=["cnn", "snn"], default="cnn", help="Neural network architecture to run. Use cnn for the recommended matrix-accelerator demo path.")
    parser.add_argument("--backend", choices=["software", "fpga"], default="software")
    parser.add_argument("--port", help="Serial port for FPGA mode, for example COM8 or /dev/ttyUSB0")
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--pad", type=int, default=2, help="Extra padding around the cropped digit before normalization.")
    parser.add_argument("--send-interval", type=float, default=DEFAULT_SEND_INTERVAL_S, help="Minimum delay between live inference launches.")
    parser.add_argument("--retrain-model", action="store_true")
    parser.add_argument("--fpga-clock-hz", type=int, default=25_000_000, help="Core clock used to convert cycle counts into milliseconds.")
    parser.add_argument("--no-board-display", action="store_true", help="Do not push the final prediction back to the board display path.")
    args = parser.parse_args()

    app = RealTimeDigitDemo(args)
    app.run()


if __name__ == "__main__":
    main()
