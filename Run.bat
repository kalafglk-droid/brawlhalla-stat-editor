@echo off
cd /d "%~dp0"
set "found="
for %%f in ("%~dp0*.ps1") do if not defined found (
    set "found=1"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%%~f"
)
if not defined found (
    echo No .ps1 file found in this folder.
    pause
    exit /b 1
)
if errorlevel 1 pause
