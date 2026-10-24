@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions
title Xiaoguai Armor v0.4.3 - Uninstall from DeepSeek Harness

if not exist "%~dp0uninstall-lite.ps1" goto :nops

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-lite.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" echo   [X] Uninstall failed. Exit code %RC%.
echo.
if not "%DSH_UNINSTALL_NO_PAUSE%"=="1" pause
exit /b %RC%

:nops
echo.
echo   [X] uninstall-lite.ps1 is missing. Use the full package.
echo.
if not "%DSH_UNINSTALL_NO_PAUSE%"=="1" pause
exit /b 2