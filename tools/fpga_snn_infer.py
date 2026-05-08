import os
import time
import numpy as np

from PIL import Image, ImageOps
from scipy.ndimage import center_of_mass, shift
from fpga_cnn_infer import FpgaSquareBackend, SoftwareSquareBackend, generalized_matmul

Q_SCALE = 256
Q_FRAC_BITS = 8
LIF_BETA_Q = 230
THRESHOLD_Q = 256
NUM_STEPS = 20
GRID_SIZE = 16

FRAME_START       = 0xA5
CMD_WRITE_SNN_IMG = 0x21
CMD_START_SNN     = 0x22
CMD_STATUS_SNN    = 0x23
RESP_ACK          = 0x5A
RESP_ERROR        = 0xE0
RESP_STATUS       = 0xA6

class FpgaSnnModel:
    def __init__(self, w1, w2, b1, b2):
        self.w1 = w1
        self.w2 = w2
        self.b1 = b1
        self.b2 = b2
        self.labels = [str(i) for i in range(10)]
        self.model_kind = "snn"

def load_snn_model():
    weights_file = os.path.join(os.path.dirname(__file__), 'snn_weights.npz')
    if not os.path.exists(weights_file):
        raise RuntimeError("Weights file not found. Please run extract_weights.py first.")
    data = np.load(weights_file)
    return FpgaSnnModel(data['w1'], data['w2'], data['b1'], data['b2'])

def preprocess_snn_image(image_array: np.ndarray, target_size=16, occupy_frac=0.80):
    arr = np.asarray(image_array, dtype=np.float32)
    if arr.size == 0:
        return np.zeros((target_size, target_size), dtype=np.float32)

    if arr.max() > 1.0 or arr.min() < 0.0:
        arr = np.clip(arr, 0.0, 255.0) / 255.0
    else:
        arr = np.clip(arr, 0.0, 1.0)

    image = Image.fromarray(np.rint(arr * 255.0).astype(np.uint8), mode="L")
    image = ImageOps.autocontrast(image)
    img2 = np.array(image, dtype=np.float32) / 255.0
    if img2.max() <= 1e-6:
        return np.zeros((target_size, target_size), dtype=np.float32)

    thresh = max(0.05, float(img2.max()) * 0.15)
    bright_fg = img2 >= thresh
    dark_fg = img2 <= thresh
    foreground_is_bright = int(bright_fg.sum()) <= int(dark_fg.sum())
    foreground = bright_fg if foreground_is_bright else dark_fg
    coords = np.argwhere(foreground)
    if coords.size == 0:
        return np.zeros((target_size, target_size), dtype=np.float32)

    ymin, xmin = coords.min(axis=0)
    ymax, xmax = coords.max(axis=0)
    cropped = img2[ymin:ymax+1, xmin:xmax+1]
    if not foreground_is_bright:
        cropped = 1.0 - cropped

    cropped = cropped - cropped.min()
    if cropped.max() > 1e-6:
        cropped = cropped / cropped.max()
    
    h, w = cropped.shape
    scale_target = max(1, int(target_size * occupy_frac))
    scale = scale_target / max(h, w)
    new_h = max(1, int(round(h * scale)))
    new_w = max(1, int(round(w * scale)))
    
    pil = Image.fromarray((cropped * 255).astype(np.uint8))
    pil_resized = pil.resize((new_w, new_h), Image.Resampling.LANCZOS)
    arr_resized = np.array(pil_resized, dtype=np.float32) / 255.0
    
    final = np.zeros((target_size, target_size), dtype=np.float32)
    start_y = (target_size - new_h) // 2
    start_x = (target_size - new_w) // 2
    final[start_y:start_y+new_h, start_x:start_x+new_w] = arr_resized
    
    if final.sum() > 1e-6:
        com_y, com_x = center_of_mass(final)
        if not (np.isnan(com_y) or np.isnan(com_x)):
            desired_center = ((target_size - 1) / 2.0, (target_size - 1) / 2.0)
            shift_y = desired_center[0] - com_y
            shift_x = desired_center[1] - com_x
            final = shift(final, shift=(shift_y, shift_x), order=1, mode='constant', cval=0.0)
            
    final = np.clip(final, 0.0, 1.0)
    return final


def _send_snn_frame(serial_port, cmd: int, arg_hi: int = 0x00, arg_lo: int = 0x00, data: int = 0x00) -> None:
    serial_port.write(bytes([FRAME_START, cmd & 0xFF, arg_hi & 0xFF, arg_lo & 0xFF, data & 0xFF]))

def tpu_matmul_exact(backend, W, X):
    X_chunks = []
    X_rem = X.copy()
    while np.any(X_rem > 0):
        chunk = np.clip(X_rem, 0, 127)
        X_chunks.append(chunk.astype(np.int8))
        X_rem -= chunk
    if not X_chunks:
        X_chunks = [np.zeros_like(X, dtype=np.int8)]

    W_chunks = []
    W_rem = W.copy()
    while np.any(W_rem != 0):
        chunk = np.clip(W_rem, -127, 127)
        W_chunks.append(chunk.astype(np.int8))
        W_rem -= chunk
    if not W_chunks:
        W_chunks = [np.zeros_like(W, dtype=np.int8)]

    res = np.zeros((W.shape[0], X.shape[1]), dtype=np.int32)
    for w_chunk in W_chunks:
        for x_chunk in X_chunks:
            res += generalized_matmul(backend, w_chunk, x_chunk)
            
    return res

def run_fpga_snn_backend(image, model, backend):
    # Preprocess (image comes in as 0..1 from preprocess_snn_image)
    if image.dtype == np.float32 or image.dtype == np.float64:
        x_q = np.clip(np.rint(image * 256.0), 0, 255).astype(np.int32)
    else:
        x_q = image.astype(np.int32)
        
    x_flat = x_q.reshape(256, 1)

    # TRUE HARDWARE FPGA PATH
    if isinstance(backend, FpgaSquareBackend):
        start_time = time.perf_counter()
        
        # 1. Send the 256-byte image using the same 5-byte framing as the board RTL.
        for i in range(256):
            _send_snn_frame(backend.ser, CMD_WRITE_SNN_IMG, 0x00, i & 0xFF, int(x_flat[i, 0]) & 0xFF)
            ack = backend.ser.read(1)
            if not ack or ack[0] != RESP_ACK:
                raise RuntimeError(f"Failed to write SNN image pixel {i}")
        backend.metrics.matrix_upload_bytes += 256
        backend.metrics.matrix_upload_commands += 256
                
        # 2. Trigger SNN Inference
        _send_snn_frame(backend.ser, CMD_START_SNN, 0x00, 0x00, 0x00)
        ack = backend.ser.read(1)
        if not ack or ack[0] != RESP_ACK:
            raise RuntimeError("Failed to start SNN inference")
        backend.metrics.accelerator_calls += 1
            
        # 3. Poll for result
        prediction = -1
        while True:
            _send_snn_frame(backend.ser, CMD_STATUS_SNN, 0x00, 0x00, 0x00)
            resp = backend.ser.read(1)
            if not resp:
                raise RuntimeError("Timeout polling SNN status")
            if resp[0] == RESP_STATUS:
                data = backend.ser.read(1)
                if len(data) != 1:
                    raise RuntimeError("Short SNN status response")
                prediction = data[0] & 0x0F
                break
            if resp[0] != RESP_ERROR:
                raise RuntimeError(f"Unexpected SNN status response 0x{resp[0]:02X}")
            time.sleep(0.005)
            
        end_time = time.perf_counter()
        latency_ms = (end_time - start_time) * 1000
        
        # Formulate result dictionary
        scores = np.zeros(10, dtype=np.int32)
        scores[prediction] = 1000 # Dummy confidence for hardware execution
        
        return {
            'prediction': prediction,
            'label': str(prediction),
            'latency_ms': latency_ms,
            'scores': scores,
            'probabilities': scores / np.sum(scores) if np.sum(scores) > 0 else scores,
            'time_steps': NUM_STEPS
        }

    # SOFTWARE HYBRID PATH
    start_time = time.time()
    fc1_out_base = tpu_matmul_exact(backend, model.w1, x_flat).flatten()
    fc1_out = (fc1_out_base >> 8) + model.b1

    mem1 = np.zeros(64, dtype=np.int32)
    mem2 = np.zeros(10, dtype=np.int32)
    scores = np.zeros(10, dtype=np.int32)

    for step in range(NUM_STEPS):
        vtmp1 = (LIF_BETA_Q * mem1) >> Q_FRAC_BITS
        vtmp1 += fc1_out
        
        spikes1 = (vtmp1 > THRESHOLD_Q).astype(np.int32)
        mem1 = np.where(spikes1, vtmp1 - THRESHOLD_Q, vtmp1)
        
        spk1_int8 = spikes1.reshape(64, 1).astype(np.int8)
        # Note: spk1_int8 is 0 or 1. If we scaled it to 256, then multiplied, then right-shifted by 8, it's identical to W * spk!
        fc2_out_base = tpu_matmul_exact(backend, model.w2, spk1_int8).flatten()
        fc2_out = fc2_out_base + model.b2

        vtmp2 = (LIF_BETA_Q * mem2) >> Q_FRAC_BITS
        vtmp2 += fc2_out
        
        spikes2 = (vtmp2 > THRESHOLD_Q).astype(np.int32)
        mem2 = np.where(spikes2, vtmp2 - THRESHOLD_Q, vtmp2)
        
        scores += spikes2 * Q_SCALE
        
    end_time = time.time()
    
    pred_class = int(np.argmax(scores))
    latency_ms = (end_time - start_time) * 1000
    
    result = {
        'prediction': pred_class,
        'label': str(pred_class),
        'latency_ms': latency_ms,
        'scores': scores,
        'probabilities': scores / np.sum(scores) if np.sum(scores) > 0 else scores,
        'time_steps': NUM_STEPS
    }
    return result

if __name__ == "__main__":
    model = load_snn_model()
    print("Loaded SNN Model successfully.")
    test_img = np.random.rand(16, 16).astype(np.float32)
    backend = SoftwareSquareBackend()
    res = run_fpga_snn_backend(test_img, model, backend)
    print("Test inference result:", res)
