@echo off
setlocal
cd /d "%~dp0.."
where py >nul 2>nul
if exist "sim\output\matmul_case.txt" (
    if %errorlevel%==0 (
        py -3 "tools\check_output.py" "sim\output\matmul_case.txt"
        exit /b %errorlevel%
    )
    python "tools\check_output.py" "sim\output\matmul_case.txt"
    exit /b %errorlevel%
)
if %errorlevel%==0 (
    py -3 "tools\check_output.py" "sim\output\matrix_a.txt" "sim\output\matrix_b.txt" "sim\output\matrix_c_hw.txt"
    exit /b %errorlevel%
)
python "tools\check_output.py" "sim\output\matrix_a.txt" "sim\output\matrix_b.txt" "sim\output\matrix_c_hw.txt"
