@echo off
setlocal
cd /d "%~dp0.."
if "%1"=="" (
    echo Usage: batch_files\run_fpga_random.bat COM5 [N] [SEED]
    exit /b 1
)
set PORT=%1
set N=%2
set SEED=%3
if "%N%"=="" set N=32
if "%SEED%"=="" set SEED=1

if not exist tools\uart_host.exe (
    call "%~dp0build_host.bat"
    if errorlevel 1 exit /b 1
)

"tools\uart_host.exe" --port "%PORT%" --random --n "%N%" --seed "%SEED%" --out-dir "fpga_output"
