@echo off
title Launching Video-to-Audio Tool...
cd /d "%~dp0"

REM Prefer pythonw (no console window behind the GUI)
where pythonw >nul 2>nul
if not errorlevel 1 (
    start "" pythonw "video2audio.pyw"
    exit /b
)

REM Fall back to python (will show a console window, harmless)
where python >nul 2>nul
if not errorlevel 1 (
    start "" python "video2audio.pyw"
    exit /b
)

echo [ERROR] Python was not found in PATH.
echo Please install Python 3.x from https://www.python.org/ and add it to PATH.
pause
exit /b 1
