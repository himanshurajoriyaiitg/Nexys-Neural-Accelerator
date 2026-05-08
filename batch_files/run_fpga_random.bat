@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0.."
if "%1"=="" (
    echo Usage: batch_files\run_fpga_random.bat COM5 [N] [SEED]
    exit /b 1
)
set PORT=%1
set N=%2
set SEED=%3
set BIAS=%4
set BIAS_VEC=%~5
set ACTIVATION=%~6
set POOL=%7
if "%N%"=="" set N=32
if "%SEED%"=="" set SEED=1
if "%BIAS_VEC%"=="-" set BIAS_VEC=
if "%ACTIVATION%"=="" set ACTIVATION=NONE

if not exist build\uart_host.exe (
    call "%~dp0build_host.bat"
    if errorlevel 1 exit /b 1
)

set CMD="build\uart_host.exe" --port "%PORT%" --random --n "%N%" --seed "%SEED%" --out-dir "fpga_output"
if /I "%BIAS%"=="1" set CMD=!CMD! --bias
if not "%BIAS_VEC%"=="" set CMD=!CMD! --bias-vec "%BIAS_VEC%"
if /I not "%ACTIVATION%"=="NONE" set CMD=!CMD! --activation "%ACTIVATION%"
if /I "%POOL%"=="1" set CMD=!CMD! --pool

call !CMD!
