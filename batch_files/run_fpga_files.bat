@echo off
setlocal
cd /d "%~dp0"
if "%3"=="" (
    echo Usage: run_fpga_files.bat COM5 matrix_a.txt matrix_b.txt [N]
    exit /b 1
)
set PORT=%1
set MATRIX_A=%2
set MATRIX_B=%3
set N=%4
if "%N%"=="" set N=8

if not exist tools\uart_host.exe (
    call build_host.bat
    if errorlevel 1 exit /b 1
)

"tools\uart_host.exe" --port "%PORT%" --matrix-a "%MATRIX_A%" --matrix-b "%MATRIX_B%" --n "%N%" --out-dir "fpga_output"
