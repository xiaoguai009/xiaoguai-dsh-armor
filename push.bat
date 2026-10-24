@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions
title Xiaoguai DSH Armor - Push to GitHub
echo.
echo   Usage:
echo     push.bat ghp_your_token
echo     push.bat ghp_your_token my-repo
echo.
if "%~1"=="" goto :usage
set "TOKEN=%~1"
set "REPO=%~2"
if "%REPO%"=="" set "REPO=xiaoguai-dsh-armor"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0push.ps1" -Token "%TOKEN%" -Repo "%REPO%"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo   [X] Push failed. Exit code %RC%.
pause
exit /b %RC%

:usage
echo   [X] Missing token. Get one at: https://github.com/settings/tokens
echo       Scope needed: repo (classic) or Contents:Read+Write (fine-grained)
echo.
pause
exit /b 2