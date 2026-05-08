import time
import argparse
import tkinter as tk
from realtime_fpga_digit_demo import RealTimeDigitDemo
import threading

def headless_test():
    args = argparse.Namespace(backend="software", port=None, baud=921600, pad=2, send_interval=0.1, retrain_model=False, fpga_clock_hz=25000000, no_board_display=True, model="cnn")
    app = RealTimeDigitDemo(args)
    
    # Paint something .
    app._update_cell(16, 16, 255)
    app._update_cell(16, 17, 255)
    app.dirty = True
    
    def simulate():
        time.sleep(1)
        print("Latency MS:", app.lbl_latency.cget("text"))
        print("Prediction:", app.lbl_prediction.cget("text"))
        app.close()
        
    threading.Thread(target=simulate, daemon=True).start()
    app.run()

if __name__ == "__main__":
    headless_test()
