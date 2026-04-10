@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if %errorlevel%==0 (
    py -3 "tools\check_output.py" "fpga_output\matrix_a.txt" "fpga_output\matrix_b.txt" "fpga_output\matrix_c_fpga.txt"
    exit /b %errorlevel%
)
python "tools\check_output.py" "fpga_output\matrix_a.txt" "fpga_output\matrix_b.txt" "fpga_output\matrix_c_fpga.txt"
