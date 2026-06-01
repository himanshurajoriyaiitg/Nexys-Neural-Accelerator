# Project Overview

The FPGA design exposes two hardware compute paths:

1. Matrix accelerator path:
   PC host -> UART -> A/B/Bias memories -> tiled systolic array -> C memory -> UART dump.
2. SNN recognizer path:
   PC/iPad image -> UART image upload -> `snn_core` -> prediction -> UART status/display.

The software tools also support local-only recognizer modes for development,
testing, and comparison before using the board.

## Quick Links

- [Key Features](#key-features)
- [Requirements](#requirements)
- [Recognizer Run Guide](#recognizer-run-guide)
- [Common Setup](#common-setup)
- [Run Recognizer On PC Using Software](#1-run-recognizer-on-pc-using-software)
- [Run Recognizer On FPGA Without iPad](#2-run-recognizer-on-fpga-without-ipad)
- [Run Recognizer On FPGA Using iPad](#3-run-recognizer-on-fpga-using-ipad)
- [FPGA LED Mapping](#fpga-led-mapping)
- [Data Flow](#data-flow)
- [Overall System Data Flow](#overall-system-data-flow)
- [Matrix Multiplication Path](#2-matrix-multiplication-path)
- [Matrix Accelerator Internal Data Flow](#matrix-accelerator-internal-data-flow)
- [Systolic Array and Diagonal Dataflow](#systolic-array-and-diagonal-dataflow)
- [FPGA Recognizer With iPad](#fpga-recognizer-with-ipad)
- [Demo Video](#-demo-video)

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

This section shows how to run the recognizer in the three required modes:

1. On PC using software
2. On FPGA without iPad
3. On FPGA using iPad

## Common Setup

Install the Python packages once:

```powershell
pip install numpy pillow scipy pyserial scikit-learn
```

For FPGA modes, first create/open the Vivado project:
open the project directory and run 
```powershell
make vivado
```

Then generate the bitstream in Vivado and program the Nexys A7 board.

To find the FPGA serial port on Windows:

```powershell
Get-PnpDevice -Class Ports
```

## 1. Run Recognizer On PC Using Software

This mode runs everything on the laptop. It does not need the FPGA board.

CNN model:

```powershell
make realtime-demo BACKEND=software MODEL=cnn
```

SNN model:

```powershell
make realtime-demo BACKEND=software MODEL=snn
```

You can also classify one built-in template:

```powershell
make char-demo BACKEND=software PIPELINE=template CHARSET=alnum LABEL=A
```

## 2. Run Recognizer On FPGA Without iPad

Use this mode when you want to draw/classify from the laptop, but run inference through the FPGA.

First program the FPGA from Vivado. Then run the PC demo with the FPGA backend.

CNN model through FPGA:

```powershell
make realtime-demo BACKEND=fpga MODEL=cnn PORT=COM8
```

SNN model through FPGA:

```powershell
make realtime-demo BACKEND=fpga MODEL=snn PORT=COM8
```

To classify a single image through the FPGA CNN path:

```powershell
python tools/fpga_cnn_infer.py --backend fpga --port COM8 --charset digits --image-file path\to\digit.png --set-led
```

## 3. Run Recognizer On FPGA Using iPad

Use this mode when the iPad is the drawing interface and the laptop acts as the web server connected to the FPGA.

First program the FPGA from Vivado. Then start the browser demo server on the laptop.

CNN iPad mode:

```powershell
make ipad-demo MODEL=cnn BACKEND=fpga PORT=COM8 HOST=0.0.0.0 WEB_PORT=8000
```

SNN iPad mode:

```powershell
make ipad-demo MODEL=snn BACKEND=fpga PORT=COM8 HOST=0.0.0.0 WEB_PORT=8000
```

You can also run the same command directly:

```powershell
python tools/ipad_fpga_digit_demo.py --model snn --backend fpga --serial-port COM8 --host 0.0.0.0 --http-port 8000
```

Open this address on the iPad browser:

```text
http://<your-laptop-ip>:8000
```

To find your laptop IP on Windows:

```powershell
ipconfig
```

Use the IPv4 address of the Wi-Fi adapter that is on the same network as the iPad i.e 
make sure both the laptop and the ipad is on same wifi network.

For UI testing without the FPGA, run:

```powershell
make ipad-demo MODEL=cnn BACKEND=software HOST=0.0.0.0 WEB_PORT=8000
```

## FPGA LED Mapping
When the recognizer sends `CMD_SET_LED_CODE`, the board displays the predicted label/code:

| Output | Meaning |
| --- | --- |
| `LED[7:0]` | Predicted digit/character code sent by software. |
| `LED[8]` | Valid prediction code is present. |
| `LED[9]` | Done/status indicator. |
| `LED[10]` | Overflow flag from the matrix accelerator path. |
| `LED[11]` | UART transmit activity. |
| `LED[12]` | UART receive activity. |
| `LED[13]` | Recent busy activity. |
| `LED[14]` | Matrix run/load/writeback activity was seen. |
| `LED[15]` | Heartbeat. |
| Seven-segment display | Shows the prediction code when available. |


# Data Flow
## Overall System Data Flow
```mermaid
flowchart LR
    User[User input] --> Tools[Python and C host tools]
    Tools --> Mode{Selected path}

    Mode --> Matmul[Matrix multiplication path]
    Mode --> Recog[Recognizer path]

    Matmul --> UART[UART command frames]
    Recog --> Soft[Software inference]
    Recog --> UART

    UART --> FPGA[nexys_a7_top.v]
    FPGA --> TPU[tpu_top.sv matrix accelerator]
    FPGA --> SNN[snn_core.sv]

    TPU --> MatResult[Matrix C result]
    SNN --> SnnResult[SNN prediction]
    Soft --> SoftResult[Software prediction]

    MatResult --> HostCheck[Host verification / output files]
    SnnResult --> HostUI[PC or iPad UI]
    SoftResult --> HostUI
    FPGA --> BoardDisplay[LEDs and seven-segment display]
```

## 2. Matrix Multiplication Path

### Matrix Multiplication Top-Level Flow

```mermaid
flowchart TD
    InputA[Matrix A input] --> Host[Host program]
    InputB[Matrix B input] --> Host
    Bias[Optional bias vector] --> Host
    Modes[Mode options: bias, activation, pool] --> Host

    Host --> Frames[UART frames]
    Frames --> Top[nexys_a7_top.v command parser]

    Top --> AMem[A BRAM write]
    Top --> BMem[B BRAM write]
    Top --> BiasMem[Bias memory write]
    Top --> Start[CMD_START with N and mode bits]

    Start --> TPU[tpu_top.sv]
    AMem --> TPU
    BMem --> TPU
    BiasMem --> TPU

    TPU --> Controller[controller.sv FSM]
    Controller --> Array[systolic_array.sv]
    Array --> Post[Optional bias, activation, pool]
    Post --> CMem[C BRAM]

    CMem --> Dump[CMD_DUMP_C over UART]
    Dump --> Host
    Host --> Files[fpga_output files]
    Files --> Check[tools/check_output.py]
    Check --> PassFail[PASS / FAIL]
```

### Matrix Accelerator Internal Data Flow

```mermaid
flowchart LR
    Cmd[UART command parser] --> AWrite[a_wr_en / a_wr_addr / a_wr_data]
    Cmd --> BWrite[b_wr_en / b_wr_addr / b_wr_data]
    Cmd --> BiasWrite[bias_wr_en / bias_wr_addr / bias_wr_data]
    Cmd --> Start[start, matrix_dim, act_mode, enable_bias, enable_pool]

    AWrite --> ABRAM[a_bram.v]
    BWrite --> BBRAM[b_bram.v]
    BiasWrite --> BiasRAM[bias_mem in tpu_top.sv]

    Start --> Ctrl[controller.sv]
    Ctrl --> Load[Tile load]
    Load --> ABRAM
    Load --> BBRAM

    ABRAM --> FeedA[A row feed]
    BBRAM --> FeedB[B column feed]
    FeedA --> Array[systolic_array.sv]
    FeedB --> Array

    Ctrl --> ClearAcc[clear_acc]
    Ctrl --> Run[run_en]
    ClearAcc --> Array
    Run --> Array

    Array --> Accum[PE accumulated tile result]
    Accum --> Modes[Bias / activation / pool logic]
    BiasRAM --> Modes
    Modes --> CBRAM[c_bram.v]
    CBRAM --> Readback[c_host_rd_data]
```


### Systolic Array and Diagonal Dataflow

The array is an ARRAY_N × ARRAY_N mesh of processing elements. Inputs are **skewed** so that each diagonal of A and B arrives at the correct PE at the correct clock cycle.

```
Cycle 0:   A[0][0] enters row 0,  B[0][0] enters col 0
Cycle 1:   A[0][1] enters row 0,  A[1][0] enters row 1
           B[1][0] enters col 0,  B[0][1] enters col 1
Cycle 2:   All diagonals shift one step further right / down
...
```
Data flow inside the mesh (4×4 example):

![Systolic Array](docs/diagrams/systolic_array_diagonal_dataflow.svg)

A values flow RIGHT (horizontally), forwarded by each PE.
B values flow DOWN  (vertically),  forwarded by each PE.
Each PE accumulates:  acc += a_in × b_in

After `(2 × ARRAY_N − 1)` run cycles the last diagonal has drained and every PE holds its final partial sum. The controller then reads out all accumulator values and writes them to C BRAM.

For matrices larger than ARRAY_N the controller tiles the computation: it loops over `tile_row`, `tile_col`, and `tile_k`, clearing the PE accumulators between tiles and accumulating partial results into C BRAM.

---

A values move horizontally across each row. B values move vertically down each column. Each PE performs:

```text
accumulator = accumulator + a_in * b_in
```


## FPGA Recognizer With iPad

```mermaid
flowchart TD
    IPad[iPad browser canvas] --> HTTP[HTTP request to laptop server]
    HTTP --> Server[tools/ipad_fpga_digit_demo.py]
    Server --> Pre[Server-side preprocessing]
    Pre --> Model{CNN or SNN}

    Model -->|CNN FPGA| CnnBackend[FPGA CNN backend]
    CnnBackend --> UARTMat[UART matrix accelerator commands]
    UARTMat --> TPU[tpu_top.sv]
    TPU --> UARTMatResult[UART matrix result]
    UARTMatResult --> Server

    Model -->|SNN FPGA| SnnBackend[FPGA SNN backend]
    SnnBackend --> UARTImg[UART image pixel commands]
    UARTImg --> SNN[snn_core.sv]
    SNN --> UARTPred[UART prediction status]
    UARTPred --> Server

    Server --> Response[Prediction response]
    Response --> IPad
    Server --> BoardDisplay[Optional board display code]
```
## 🎥 Demo Video

[![Watch the Demo](https://img.youtube.com/vi/Vqjhe0MYNfY/0.jpg)](https://www.youtube.com/watch?v=Vqjhe0MYNfY)
