#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import threading
import time
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

import numpy as np

from fpga_cnn_infer import FpgaSquareBackend, SoftwareSquareBackend, label_to_led_code, run_fpga_cnn_backend
from fpga_cnn_model import GRID_SIZE as CNN_GRID_SIZE, load_or_train_model as load_cnn_model
from fpga_snn_infer import GRID_SIZE as SNN_GRID_SIZE, load_snn_model, preprocess_snn_image, run_fpga_snn_backend
from handwritten_digit_pipeline import preprocess_handwritten_array


WORK_GRID_SIZE = 32


HTML_PAGE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>FPGA Digit Demo</title>
  <style>
    :root {
      --paper: #f7f1e5;
      --ink: #172033;
      --accent: #b4512d;
      --panel: rgba(255, 255, 255, 0.75);
      --shadow: 0 24px 60px rgba(23, 32, 51, 0.12);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      font-family: "Avenir Next", "Segoe UI", sans-serif;
      color: var(--ink);
      background:
        radial-gradient(circle at top left, rgba(180, 81, 45, 0.18), transparent 28rem),
        radial-gradient(circle at bottom right, rgba(44, 111, 134, 0.16), transparent 24rem),
        linear-gradient(160deg, #fef9ef 0%, var(--paper) 100%);
    }
    .wrap {
      max-width: 980px;
      margin: 0 auto;
      padding: 24px 18px 40px;
    }
    .hero {
      display: grid;
      gap: 18px;
      grid-template-columns: 1.1fr 0.9fr;
      align-items: stretch;
    }
    .card {
      background: var(--panel);
      backdrop-filter: blur(10px);
      border: 1px solid rgba(255, 255, 255, 0.65);
      border-radius: 24px;
      box-shadow: var(--shadow);
    }
    .headline {
      padding: 24px;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      gap: 18px;
    }
    h1 {
      margin: 0;
      font-size: clamp(2rem, 5vw, 3.6rem);
      line-height: 0.95;
      letter-spacing: -0.05em;
    }
    .sub {
      margin: 0;
      font-size: 1rem;
      line-height: 1.6;
      color: rgba(23, 32, 51, 0.78);
    }
    .meta {
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
    }
    .pill {
      border-radius: 999px;
      padding: 10px 14px;
      background: rgba(23, 32, 51, 0.06);
      border: 1px solid rgba(23, 32, 51, 0.08);
      font-size: 0.92rem;
    }
    .board {
      padding: 20px;
      display: grid;
      gap: 12px;
      align-content: start;
    }
    .canvas-shell {
      position: relative;
      width: min(88vw, 520px);
      aspect-ratio: 1;
      margin: 0 auto;
      border-radius: 22px;
      overflow: hidden;
      border: 1px solid rgba(23, 32, 51, 0.14);
      background:
        linear-gradient(rgba(23, 32, 51, 0.08) 1px, transparent 1px),
        linear-gradient(90deg, rgba(23, 32, 51, 0.08) 1px, transparent 1px),
        #ffffff;
      background-size: calc(100% / 16) calc(100% / 16), calc(100% / 16) calc(100% / 16), auto;
    }
    canvas {
      width: 100%;
      height: 100%;
      touch-action: none;
      display: block;
    }
    .toolbar {
      display: flex;
      justify-content: space-between;
      gap: 10px;
      flex-wrap: wrap;
      align-items: center;
    }
    .toolbar button {
      border: 0;
      border-radius: 999px;
      padding: 12px 18px;
      font-size: 0.95rem;
      font-weight: 600;
      cursor: pointer;
    }
    .toolbar .primary {
      background: var(--ink);
      color: white;
    }
    .toolbar .secondary {
      background: rgba(23, 32, 51, 0.08);
      color: var(--ink);
    }
    .result {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 12px;
      margin-top: 12px;
    }
    .metric {
      padding: 16px;
      border-radius: 18px;
      background: rgba(255, 255, 255, 0.82);
      border: 1px solid rgba(23, 32, 51, 0.08);
    }
    .metric small {
      display: block;
      color: rgba(23, 32, 51, 0.6);
      margin-bottom: 6px;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      font-size: 0.72rem;
    }
    .metric strong {
      font-size: clamp(1.1rem, 3.8vw, 2.4rem);
      letter-spacing: -0.04em;
    }
    .status {
      padding: 16px 18px;
      border-radius: 18px;
      background: rgba(180, 81, 45, 0.08);
      border: 1px solid rgba(180, 81, 45, 0.12);
      color: rgba(23, 32, 51, 0.82);
      min-height: 56px;
    }
    @media (max-width: 860px) {
      .hero { grid-template-columns: 1fr; }
      .result { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <div class="wrap">
    <section class="hero">
      <div class="card headline">
        <div>
          <h1>Write on the iPad.<br>Show on the FPGA.</h1>
          <p class="sub">
            Draw one digit in the pad. The laptop runs the project backend, pushes the final result to the FPGA display path,
            and returns the confidence and latency to this page.
          </p>
        </div>
        <div class="meta">
          <span class="pill" id="meta-model">Model: --</span>
          <span class="pill" id="meta-backend">Backend: --</span>
          <span class="pill">Canvas: 32x32 capture</span>
        </div>
      </div>
      <div class="card board">
        <div class="canvas-shell">
          <canvas id="draw" width="512" height="512"></canvas>
        </div>
        <div class="toolbar">
          <button class="primary" id="predict">Predict Now</button>
          <button class="secondary" id="clear">Clear</button>
        </div>
        <div class="status" id="status">Draw a digit, then pause for live prediction or press Predict Now.</div>
        <div class="result">
          <div class="metric">
            <small>Prediction</small>
            <strong id="prediction">--</strong>
          </div>
          <div class="metric">
            <small>Confidence</small>
            <strong id="confidence">--</strong>
          </div>
          <div class="metric">
            <small>Latency</small>
            <strong id="latency">--</strong>
          </div>
        </div>
      </div>
    </section>
  </div>
  <script>
    const canvas = document.getElementById("draw");
    const ctx = canvas.getContext("2d");
    const metaModel = document.getElementById("meta-model");
    const metaBackend = document.getElementById("meta-backend");
    const statusEl = document.getElementById("status");
    const predictionEl = document.getElementById("prediction");
    const confidenceEl = document.getElementById("confidence");
    const latencyEl = document.getElementById("latency");
    const predictButton = document.getElementById("predict");
    const clearButton = document.getElementById("clear");

    metaModel.textContent = "Model: {{MODEL}}";
    metaBackend.textContent = "Backend: {{BACKEND}}";

    function resetCanvas() {
      ctx.fillStyle = "#ffffff";
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      statusEl.textContent = "Draw a digit, then pause for live prediction or press Predict Now.";
      predictionEl.textContent = "--";
      confidenceEl.textContent = "--";
      latencyEl.textContent = "--";
    }

    resetCanvas();

    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.strokeStyle = "#101010";

    let drawing = false;
    let predictTimer = null;

    function pointFromEvent(event) {
      const rect = canvas.getBoundingClientRect();
      return {
        x: (event.clientX - rect.left) * (canvas.width / rect.width),
        y: (event.clientY - rect.top) * (canvas.height / rect.height),
      };
    }

    function schedulePredict() {
      if (predictTimer) {
        clearTimeout(predictTimer);
      }
      predictTimer = setTimeout(() => {
        sendPrediction();
      }, 180);
    }

    function startDraw(event) {
      event.preventDefault();
      drawing = true;
      const point = pointFromEvent(event);
      ctx.beginPath();
      ctx.moveTo(point.x, point.y);
    }

    function moveDraw(event) {
      if (!drawing) {
        return;
      }
      event.preventDefault();
      const point = pointFromEvent(event);
      ctx.lineWidth = canvas.width / 18;
      ctx.lineTo(point.x, point.y);
      ctx.stroke();
      schedulePredict();
    }

    function endDraw(event) {
      if (!drawing) {
        return;
      }
      event.preventDefault();
      drawing = false;
      schedulePredict();
    }

    canvas.addEventListener("pointerdown", startDraw);
    canvas.addEventListener("pointermove", moveDraw);
    canvas.addEventListener("pointerup", endDraw);
    canvas.addEventListener("pointerleave", endDraw);
    canvas.addEventListener("pointercancel", endDraw);

    function canvasToGrid() {
      const capture = document.createElement("canvas");
      capture.width = 32;
      capture.height = 32;
      const captureCtx = capture.getContext("2d");
      captureCtx.fillStyle = "#ffffff";
      captureCtx.fillRect(0, 0, 32, 32);
      captureCtx.drawImage(canvas, 0, 0, 32, 32);
      const imageData = captureCtx.getImageData(0, 0, 32, 32).data;
      const grid = [];
      for (let row = 0; row < 32; row++) {
        const current = [];
        for (let col = 0; col < 32; col++) {
          const offset = (row * 32 + col) * 4;
          current.push(255 - imageData[offset]);
        }
        grid.push(current);
      }
      return grid;
    }

    async function sendPrediction() {
      const grid = canvasToGrid();
      const ink = grid.flat().reduce((sum, value) => sum + value, 0);
      if (ink < 25) {
        statusEl.textContent = "Canvas is empty. Draw one digit first.";
        predictionEl.textContent = "--";
        confidenceEl.textContent = "--";
        latencyEl.textContent = "--";
        return;
      }

      statusEl.textContent = "Running prediction...";
      try {
        const response = await fetch("/predict", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ grid }),
        });
        const payload = await response.json();
        if (!response.ok) {
          throw new Error(payload.error || "Prediction failed");
        }

        statusEl.textContent = payload.status;
        predictionEl.textContent = payload.prediction;
        confidenceEl.textContent = `${(payload.confidence * 100).toFixed(1)}%`;
        latencyEl.textContent = payload.latency;
      } catch (error) {
        statusEl.textContent = `Prediction failed: ${error.message}`;
        predictionEl.textContent = "error";
        confidenceEl.textContent = "--";
        latencyEl.textContent = "--";
      }
    }

    predictButton.addEventListener("click", sendPrediction);
    clearButton.addEventListener("click", resetCanvas);
  </script>
</body>
</html>
"""


@dataclass
class PredictionSummary:
    prediction: str
    confidence: float
    latency_text: str
    status: str


class DemoState:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.lock = threading.Lock()
        self.model_name = args.model
        self.backend_name = args.backend
        self.grid_size = SNN_GRID_SIZE if args.model == "snn" else CNN_GRID_SIZE

        if args.model == "snn":
            self.model = load_snn_model()
        else:
            self.model = load_cnn_model("digits", force_retrain=args.retrain_model)

        if args.backend == "fpga":
            if not args.serial_port:
                raise SystemExit("--serial-port is required when --backend fpga.")
            self.backend = FpgaSquareBackend(args.serial_port, args.baud)
        else:
            self.backend = SoftwareSquareBackend()

    def close(self) -> None:
        if hasattr(self.backend, "close"):
            self.backend.close()

    def predict(self, grid: np.ndarray) -> PredictionSummary:
        with self.lock:
            start_time = time.perf_counter()
            self.backend.reset_metrics()
            native_board_display = self.args.backend == "fpga" and self.args.model == "snn"

            if self.args.model == "snn":
                normalized = preprocess_snn_image(grid, target_size=self.grid_size)
                result = run_fpga_snn_backend(normalized, self.model, self.backend)
                prediction = str(result["label"])
                probabilities = np.asarray(result["probabilities"], dtype=np.float64)
                confidence = float(probabilities[int(result["prediction"])]) if probabilities.sum() > 0 else 0.0
                latency_text = f"{result['latency_ms']:.1f} ms host"
            else:
                normalized = preprocess_handwritten_array(
                    grid,
                    invert=False,
                    threshold=None,
                    pad=max(2, self.args.pad),
                    target_size=self.grid_size,
                )
                logits = run_fpga_cnn_backend(normalized, self.model, self.backend)
                shifted = logits - np.max(logits)
                exp_logits = np.exp(shifted)
                probabilities = exp_logits / np.sum(exp_logits)
                best_index = int(np.argmax(probabilities))
                prediction = self.model.labels[best_index]
                confidence = float(probabilities[best_index])
                elapsed_ms = (time.perf_counter() - start_time) * 1000.0
                if self.backend.metrics.total_cycle_count > 0:
                    core_ms = (self.backend.metrics.total_cycle_count / float(self.args.fpga_clock_hz)) * 1000.0
                    latency_text = f"{elapsed_ms:.1f} ms host | {core_ms:.3f} ms core"
                else:
                    latency_text = f"{elapsed_ms:.1f} ms host"

            if self.args.backend == "fpga" and not self.args.no_board_display and not native_board_display:
                self.backend.set_led_code(label_to_led_code(prediction))

            return PredictionSummary(
                prediction=prediction,
                confidence=confidence,
                latency_text=latency_text,
                status=(
                    "Prediction complete. The FPGA inferred and updated the board display."
                    if native_board_display
                    else "Prediction complete. The FPGA display path has been updated."
                    if self.args.backend == "fpga" and not self.args.no_board_display
                    else "Prediction complete."
                ),
            )


def make_handler(state: DemoState):
    class DemoHandler(BaseHTTPRequestHandler):
        def _send_json(self, payload: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _send_html(self, body: str) -> None:
            encoded = body.encode("utf-8")
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def do_GET(self) -> None:
            if self.path in {"/", "/index.html"}:
                page = HTML_PAGE.replace("{{MODEL}}", state.model_name.upper()).replace("{{BACKEND}}", state.backend_name.upper())
                self._send_html(page)
                return

            if self.path == "/health":
                self._send_json({"ok": True, "model": state.model_name, "backend": state.backend_name})
                return

            self._send_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)

        def do_POST(self) -> None:
            if self.path != "/predict":
                self._send_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)
                return

            content_length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(content_length)
            try:
                payload = json.loads(raw.decode("utf-8"))
                grid = np.asarray(payload["grid"], dtype=np.uint8)
                if grid.shape != (WORK_GRID_SIZE, WORK_GRID_SIZE):
                    raise ValueError(f"grid must be {WORK_GRID_SIZE}x{WORK_GRID_SIZE}")
                summary = state.predict(grid)
            except Exception as exc:
                self._send_json({"error": str(exc)}, status=HTTPStatus.BAD_REQUEST)
                return

            self._send_json(
                {
                    "prediction": summary.prediction,
                    "confidence": summary.confidence,
                    "latency": summary.latency_text,
                    "status": summary.status,
                }
            )

        def log_message(self, format: str, *args: Any) -> None:
            return

    return DemoHandler


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Serve an iPad-friendly digit drawing page that runs this repo's predictor on the laptop "
            "and optionally pushes the final prediction to the FPGA display path."
        )
    )
    parser.add_argument("--model", choices=["cnn", "snn"], default="cnn")
    parser.add_argument("--backend", choices=["software", "fpga"], default="software")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--http-port", type=int, default=8000)
    parser.add_argument("--serial-port", help="Serial/UART port for FPGA mode, for example COM8 or /dev/ttyUSB0")
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--pad", type=int, default=2)
    parser.add_argument("--retrain-model", action="store_true")
    parser.add_argument("--fpga-clock-hz", type=int, default=25_000_000)
    parser.add_argument("--no-board-display", action="store_true")
    args = parser.parse_args()

    state = DemoState(args)
    server = ThreadingHTTPServer((args.host, args.http_port), make_handler(state))

    try:
        print(f"Serving iPad digit demo on http://{args.host}:{args.http_port}")
        if args.host == "0.0.0.0":
            print("Open the same port on your laptop IP from the iPad browser.")
        print(f"Model={args.model} Backend={args.backend}")
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        state.close()


if __name__ == "__main__":
    main()
