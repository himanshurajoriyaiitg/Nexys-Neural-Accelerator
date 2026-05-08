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
