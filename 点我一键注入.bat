@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions
title Xiaoguai Armor v0.4.3 - Install to DeepSeek Harness

if not exist "%~dp0install-lite.ps1" goto :nops
if not exist "%~dp0package.json" goto :nops

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-lite.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" echo   [X] Install failed. Exit code %RC%. Read the red lines above.
echo.
if not "%DSH_INSTALL_NO_PAUSE%"=="1" pause
exit /b %RC%

:nops
echo.
echo   [X] Package incomplete: install-lite.ps1 or package.json is missing.
echo       Extract the whole folder first, do not copy this BAT alone.
echo.
if not "%DSH_INSTALL_NO_PAUSE%"=="1" pause
exit /b 2