@echo off
setlocal
title SUPER OPTIMIZER - DIAGNOSTICO DE INICIALIZACAO
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
  echo Windows PowerShell 5.1 nao encontrado em: %PS%
  pause
  exit /b 1
)
echo.
echo ===============================================================
echo  SUPER OPTIMIZER - DIAGNOSTICO DE INICIALIZACAO
echo ===============================================================
echo Esta janela ficara aberta para mostrar qualquer erro real.
echo.
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -NoExit -File "%~dp0SuperOptimizer\Launcher.ps1"
echo.
echo Se houver log, verifique:
echo %~dp0SuperOptimizer\State\Logs\startup_last_error.txt
pause
