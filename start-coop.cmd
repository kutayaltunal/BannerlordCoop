@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-coop.ps1" %*
if errorlevel 1 pause
exit /b %errorlevel%
