@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0.."
set BIAS_VEC=%~1
set ACTIVATION=%~2
set POOL=%3
if "%BIAS_VEC%"=="-" set BIAS_VEC=
if "%ACTIVATION%"=="" set ACTIVATION=NONE
set EXTRA_ARGS=
if not "%BIAS_VEC%"=="" set EXTRA_ARGS=!EXTRA_ARGS! --bias-file "%BIAS_VEC%"
if /I not "%ACTIVATION%"=="NONE" set EXTRA_ARGS=!EXTRA_ARGS! --activation "%ACTIVATION%"
if /I "%POOL%"=="1" set EXTRA_ARGS=!EXTRA_ARGS! --pool
where py >nul 2>nul
if %errorlevel%==0 (
    py -3 "tools\check_output.py" "fpga_output\matrix_a.txt" "fpga_output\matrix_b.txt" "fpga_output\matrix_c_fpga.txt" !EXTRA_ARGS!
    exit /b %errorlevel%
)
python "tools\check_output.py" "fpga_output\matrix_a.txt" "fpga_output\matrix_b.txt" "fpga_output\matrix_c_fpga.txt" !EXTRA_ARGS!
