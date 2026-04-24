ifeq ($(OS),Windows_NT)
SHELL := cmd
.SHELLFLAGS := /c
EXE := .exe
RM := del /Q
HOST_BIN := tools\uart_host.exe
BATCH_DIR := batch_files
else
EXE :=
RM := rm -f
HOST_BIN := tools/uart_host
BATCH_DIR := batch_files
endif

PORT ?= COM5
N ?= 32
SEED ?= 1
MATRIX_A ?= input_a.txt
MATRIX_B ?= input_b.txt

.PHONY: help host vivado check-sim check-fpga fpga-random fpga-files clean

help:
	@echo Targets:
	@echo   make host         - Build the Windows UART host program
	@echo   make vivado       - Open/create the Vivado project
	@echo   make check-sim    - Check sim\output files with Python
	@echo   make check-fpga   - Check fpga_output files with Python
	@echo   make fpga-random  - Run FPGA with random matrices
	@echo   make fpga-files   - Run FPGA with MATRIX_A and MATRIX_B
	@echo   make clean        - Remove built UART host executable
	@echo.
	@echo Useful variables:
	@echo   PORT=COM5
	@echo   N=32
	@echo   SEED=1
	@echo   MATRIX_A=input_a.txt MATRIX_B=input_b.txt

host:
	$(BATCH_DIR)\build_host.bat

vivado:
	$(BATCH_DIR)\open_vivado.bat

check-sim:
	$(BATCH_DIR)\check_sim.bat

check-fpga:
	$(BATCH_DIR)\check_fpga.bat

fpga-random:
	$(BATCH_DIR)\run_fpga_random.bat $(PORT) $(N) $(SEED)

fpga-files:
	$(BATCH_DIR)\run_fpga_files.bat $(PORT) $(MATRIX_A) $(MATRIX_B) $(N)

clean:
	-$(RM) $(HOST_BIN)
