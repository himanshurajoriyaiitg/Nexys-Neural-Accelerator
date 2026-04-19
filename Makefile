ifeq ($(OS),Windows_NT)
SHELL := cmd
.SHELLFLAGS := /c
EXE := .exe
RM := del /Q
HOST_BIN := tools\uart_host.exe
BAT_DIR := batch_files
SEP := \\
else
EXE :=
RM := rm -f
HOST_BIN := tools/uart_host
BAT_DIR := batch_files
SEP := /
endif

PORT ?= COM5
N ?= 8
SEED ?= 1
MATRIX_A ?= input_a.txt
MATRIX_B ?= input_b.txt

.PHONY: help host vivado check-sim check-fpga fpga-random fpga-files clean

help:
	@echo Targets:
	@echo   make host         - Build the UART host program
	@echo   make vivado       - Open/create the Vivado project
	@echo   make check-sim    - Check sim output files with Python
	@echo   make check-fpga   - Check FPGA output files with Python
	@echo   make fpga-random  - Run FPGA with random matrices
	@echo   make fpga-files   - Run FPGA with MATRIX_A and MATRIX_B
	@echo   make clean        - Remove built UART host executable
	@echo.
	@echo Useful variables:
	@echo   PORT=COM5
	@echo   N=8
	@echo   SEED=1
	@echo   MATRIX_A=input_a.txt MATRIX_B=input_b.txt

host:
	$(BAT_DIR)$(SEP)build_host.bat

vivado:
	$(BAT_DIR)$(SEP)open_vivado.bat

check-sim:
	$(BAT_DIR)$(SEP)check_sim.bat

check-fpga:
	$(BAT_DIR)$(SEP)check_fpga.bat

fpga-random:
	$(BAT_DIR)$(SEP)run_fpga_random.bat $(PORT) $(N) $(SEED)

fpga-files:
	$(BAT_DIR)$(SEP)run_fpga_files.bat $(PORT) $(MATRIX_A) $(MATRIX_B) $(N)

clean:
	-$(RM) $(HOST_BIN)