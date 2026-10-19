@echo off
chcp 65001 >nul
setlocal
title SUPER OPTIMIZER V3.9.0 DEV
cd /d "%~dp0"

set "APP=%~dp0SuperOptimizer"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%APP%\Launcher.ps1" goto missing
if not exist "%PS%" goto nops

start "" "%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%APP%\Launcher.ps1"
exit /b 0

:missing
echo.
echo [ERRO] Estrutura incompleta: SuperOptimizer\Launcher.ps1 nao foi encontrado.
echo Extraia o ZIP inteiro antes de executar.
echo.
pause
exit /b 2

:nops
echo.
echo [ERRO] Windows PowerShell 5.1 nao foi encontrado em:
echo %PS%
echo.
pause
exit /b 3
