# Project Overview

The FPGA design exposes two hardware compute paths:

1. Matrix accelerator path:
   PC host -> UART -> A/B/Bias memories -> tiled systolic array -> C memory -> UART dump.
2. SNN recognizer path:
   PC/iPad image -> UART image upload -> `snn_core` -> prediction -> UART status/display.

The software tools also support local-only recognizer modes for development,
testing, and comparison before using the board.

## Key Features

- Parameterized signed 8-bit matrix multiply with 32-bit-style accumulation.
- Default maximum matrix size: `N=32`.
- Default physical array size: `ARRAY_N=8`.
- Tiled execution for matrices larger than 8x8.
- Optional bias addition.
- Optional activation: `NONE`, `RELU`, `LEAKY_RELU`.
- Optional 2x2 max pooling.
- UART host support for random matrices, file matrices, batching, reuse, packed bursts, and zero-run compression.
- Python checker for simulation and FPGA output.
- CNN-style handwritten digit/character recognition using the matrix accelerator.
- SNN inference path using `snn_core` and `snn_weights`.
- Browser/iPad drawing demo.
- Vivado project generation through Tcl.

## Requirements

Install these before running the full project:

```powershell
pip install numpy pillow scipy pyserial scikit-learn
```

For FPGA modes you also need:

- Vivado installed and available as `vivado` or `vivado.bat`.
- Nexys A7-100T connected over USB.
- A C compiler for the host program: Visual Studio Build Tools `cl` or MinGW/GCC.
- `make` if you want to use the Makefile shortcuts.

To find the FPGA serial port on Windows:

```powershell
Get-PnpDevice -Class Ports
```

On Linux, check:

```bash
ls /dev/ttyUSB* /dev/ttyACM*
```

Use the discovered port wherever this README shows `COM8`.


# Recognizer Run Guide

This file shows only how to run the recognizer in the three required modes:

1. On PC using software
2. On FPGA without iPad
3. On FPGA using iPad


## Requirements

- Python 3
- For FPGA modes:
  - Vivado
  - Nexys A7 programmed with the project bitstream
  - USB serial connection to the board
- Python packages:

```powershell
pip install numpy pillow scipy pyserial scikit-learn
```


## 1. Run recognizer on PC using software

This opens the local draw-and-classify recognizer on your laptop.

```powershell
make realtime-demo BACKEND=software MODEL=cnn
```

## 3. Run recognizer on FPGA using iPad

First program  run  the command 

```powershell
make vivado 
```
then generate the bitstream and program the  FPGA

Then start the browser demo server:

```powershell
python tools/ipad_fpga_digit_demo.py --model snn --backend fpga --serial-port COM8 --host 0.0.0.0 --http-port 8000
```
Replace `COM8` with your FPGA serial port , to find the port run the command 
```powershell
Get-PnpDevice -Class Ports

```
above command will give result like this-
Open this on the iPad browser:

```text
http://<your-laptop-ip>:8000
```

To find your laptop IP on Windows:

```powershell
ipconfig
```

Use the IPv4 address of your active Wi-Fi connection.
