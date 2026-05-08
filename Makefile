ifeq ($(OS),Windows_NT)
SHELL := cmd
.SHELLFLAGS := /c
EXE := .exe
RM := del /Q
HOST_BIN := build\uart_host.exe
HOST_SRC := tools\uart_host.c
BATCH_DIR := batch_files
HOST_BUILD := $(BATCH_DIR)\build_host.bat
else
EXE :=
RM := rm -f
HOST_BIN := build/uart_host
HOST_SRC := tools/uart_host.c
BATCH_DIR := batch_files
CC ?= gcc
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -pedantic
HOST_BUILD := $(CC) $(CFLAGS) $(HOST_SRC) -o $(HOST_BIN)
endif

PORT ?= COM5
N ?= 32
SEED ?= 1
MATRIX_A ?= input_a.txt
MATRIX_B ?= input_b.txt
BIAS ?= 0
BIAS_VEC ?=
ACTIVATION ?= NONE
POOL ?= 0
BIAS_VEC_ARG := $(if $(BIAS_VEC),$(BIAS_VEC),-)

.PHONY: help host vivado check-sim check-fpga fpga-random fpga-files clean char-self-test char-demo digit-image cnn-image realtime-demo ipad-demo test-accuracy

help:
	@echo Targets:
	@echo   make host         - Build the UART host program
	@echo   make vivado       - Open/create the Vivado project
	@echo   make check-sim    - Check sim\output files with Python
	@echo   make check-fpga   - Check fpga_output files with Python
	@echo   make fpga-random  - Run FPGA with random matrices
	@echo   make fpga-files   - Run FPGA with MATRIX_A and MATRIX_B
	@echo   make char-self-test - Run recognizer self-test (PIPELINE=template or handwritten)
	@echo   make char-demo    - Classify one built-in digit or letter
	@echo   make digit-image  - Classify one handwritten digit image with the conv/relu/pool pipeline
	@echo   make cnn-image    - Run the FPGA-friendly CNN-style recognizer on one digit or character image
	@echo   make realtime-demo - Launch the live draw-and-classify digit demo
	@echo   make ipad-demo    - Launch the iPad browser demo server
	@echo   make test-accuracy - Evaluate cnn/handwritten/snn on local or reference samples
	@echo   make clean        - Remove built UART host executable
	@echo.
	@echo Useful variables:
	@echo   PORT=COM5
	@echo   N=32
	@echo   SEED=1
	@echo   MATRIX_A=input_a.txt MATRIX_B=input_b.txt
	@echo   BIAS=0 BIAS_VEC=bias.txt ACTIVATION=NONE POOL=0
	@echo   LABEL=A BACKEND=software CHARSET=alnum PORT=COM8 MODEL=cnn DATASET=local WEB_PORT=8000

host:
	$(HOST_BUILD)

vivado:
	$(BATCH_DIR)\open_vivado.bat

check-sim:
	$(BATCH_DIR)\check_sim.bat "$(BIAS_VEC_ARG)" "$(ACTIVATION)" "$(POOL)"

check-fpga:
	$(BATCH_DIR)\check_fpga.bat "$(BIAS_VEC_ARG)" "$(ACTIVATION)" "$(POOL)"

fpga-random:
	$(BATCH_DIR)\run_fpga_random.bat $(PORT) $(N) $(SEED) $(BIAS) "$(BIAS_VEC_ARG)" "$(ACTIVATION)" $(POOL)

fpga-files:
	$(BATCH_DIR)\run_fpga_files.bat $(PORT) $(MATRIX_A) $(MATRIX_B) $(N) $(BIAS) "$(BIAS_VEC_ARG)" "$(ACTIVATION)" $(POOL)

LABEL ?= A
BACKEND ?= software
CHARSET ?= alnum
PIPELINE ?= template
SAMPLE_DIR ?= samples/recognizer
IMAGE ?= $(SAMPLE_DIR)/five.png
MODEL ?= cnn
HOST ?= 0.0.0.0
WEB_PORT ?= 8000
DATASET ?= local

clean:
	-$(RM) $(HOST_BIN)

char-self-test:
	python tools/digit_recognizer.py --pipeline $(PIPELINE) --self-test

char-demo:
	python tools/digit_recognizer.py --pipeline $(PIPELINE) --backend $(BACKEND) --label $(LABEL) --charset $(CHARSET) $(if $(filter fpga,$(BACKEND)),--port $(PORT),)

digit-image:
	python tools/digit_recognizer.py --pipeline handwritten --backend software --charset digits --image-file $(IMAGE)

cnn-image:
	python tools/fpga_cnn_infer.py --backend $(BACKEND) --charset $(CHARSET) --image-file $(IMAGE) $(if $(filter fpga,$(BACKEND)),--port $(PORT),)

realtime-demo:
	python tools/realtime_fpga_digit_demo.py --model $(MODEL) --backend $(BACKEND) $(if $(filter fpga,$(BACKEND)),--port $(PORT),)

ipad-demo:
	python tools/ipad_fpga_digit_demo.py --model $(MODEL) --backend $(BACKEND) --host $(HOST) --http-port $(WEB_PORT) $(if $(filter fpga,$(BACKEND)),--serial-port $(PORT),)

test-accuracy:
	python tools/test_accuracy.py --model $(MODEL) --dataset $(DATASET)

.PHONY: check-normal check-bias check-relu check-leaky_relu check-pool check-all-features

check-normal:
	python tools/uart_host.py --port $(PORT) --n $(N) --seed $(SEED) --verbose

check-bias:
	python tools/uart_host.py --port $(PORT) --n $(N) --seed $(SEED) --bias --verbose

check-relu:
	python tools/uart_host.py --port $(PORT) --n $(N) --seed $(SEED) --activation RELU --verbose

check-leaky_relu:
	python tools/uart_host.py --port $(PORT) --n $(N) --seed $(SEED) --activation LEAKY_RELU --verbose

check-pool:
	python tools/uart_host.py --port $(PORT) --n $(N) --seed $(SEED) --pool --verbose

check-all-features:
	python tools/uart_host.py --port $(PORT) --n $(N) --seed $(SEED) --bias --activation LEAKY_RELU --pool --verbose
