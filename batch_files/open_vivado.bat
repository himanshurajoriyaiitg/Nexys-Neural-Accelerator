@echo off
setlocal
cd /d "%~dp0"
where vivado.bat >nul 2>nul
if %errorlevel%==0 (
    vivado.bat -source "vivado\create_project.tcl"
    exit /b %errorlevel%
)
vivado -source "vivado\create_project.tcl"
