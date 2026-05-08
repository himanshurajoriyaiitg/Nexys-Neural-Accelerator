@echo off
setlocal
cd /d "%~dp0.."
if not exist build mkdir build

where cl >nul 2>nul
if %errorlevel%==0 (
    cl /nologo /O2 /W3 /Fe:"build\uart_host.exe" "tools\uart_host.c"
    if errorlevel 1 exit /b 1
    echo Built build\uart_host.exe with MSVC
    exit /b 0
)

where gcc >nul 2>nul
if %errorlevel%==0 (
    gcc -O2 -std=c11 -Wall -Wextra -o "build\uart_host.exe" "tools\uart_host.c"
    if errorlevel 1 exit /b 1
    echo Built build\uart_host.exe with GCC
    exit /b 0
)

echo Error: no C compiler found.
echo Install one of these:
echo   1. Visual Studio Build Tools ^(cl^)
echo   2. MSYS2/MinGW GCC ^(gcc^)
exit /b 1
