import sys
import os
import numpy as np
from PIL import Image
from fpga_snn_infer import load_snn_model, run_fpga_snn_backend, preprocess_snn_image
from fpga_cnn_infer import SoftwareSquareBackend

def predict_image(image_path):
    if not os.path.exists(image_path):
        print(f"Error: Could not find image at {image_path}")
        sys.exit(1)

    print(f"Loading image: {image_path}")
    
    # 1. Load the image and convert to Grayscale
    img = Image.open(image_path).convert('L')
    
    # 2. Convert to float32 numpy array and scale to 0.0 - 1.0
    img_array = np.array(img).astype(np.float32) / 255.0
    
    # 3. Apply the exact SNN preprocessing (cropping, Center-of-Mass, Lanczos resize to 16x16)
    img_processed = preprocess_snn_image(img_array)
    
    # 4. Load the software backend and our Q8.8 quantized SNN model
    backend = SoftwareSquareBackend()
    model = load_snn_model()
    
    # 5. Run inference!
    print("Running SNN inference (Software Mode)...")
    res = run_fpga_snn_backend(img_processed, model, backend)
    
    # 6. Display results
    pred = res['prediction']
    conf = res['probabilities'][pred] * 100
    
    print("\n" + "="*30)
    print(f"Prediction:   {pred}")
    print(f"Confidence:   {conf:.2f}%")
    print(f"Latency:      {res['latency_ms']:.2f} ms")
    print("="*30)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python predict_png.py <path_to_image.png>")
        sys.exit(1)
        
    predict_image(sys.argv[1])
