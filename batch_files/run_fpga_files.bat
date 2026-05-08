@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0.."
if "%3"=="" (
    echo Usage: batch_files\run_fpga_files.bat COM5 matrix_a.txt matrix_b.txt [N]
    exit /b 1
)
set PORT=%1
set MATRIX_A=%~2
set MATRIX_B=%~3
set N=%4
set BIAS=%5
set BIAS_VEC=%~6
set ACTIVATION=%~7
set POOL=%8
if "%N%"=="" set N=32
if "%BIAS_VEC%"=="-" set BIAS_VEC=
if "%ACTIVATION%"=="" set ACTIVATION=NONE

if not exist build\uart_host.exe (
    call "%~dp0build_host.bat"
    if errorlevel 1 exit /b 1
)

set CMD="build\uart_host.exe" --port "%PORT%" --matrix-a "%MATRIX_A%" --matrix-b "%MATRIX_B%" --n "%N%" --out-dir "fpga_output"
if /I "%BIAS%"=="1" set CMD=!CMD! --bias
if not "%BIAS_VEC%"=="" set CMD=!CMD! --bias-vec "%BIAS_VEC%"
if /I not "%ACTIVATION%"=="NONE" set CMD=!CMD! --activation "%ACTIVATION%"
if /I "%POOL%"=="1" set CMD=!CMD! --pool

call !CMD!
