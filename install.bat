@echo off
setlocal
net session >nul 2>&1
if not "%errorlevel%"=="0" (
  echo Solicitando permissao de administrador...
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Force %*
if errorlevel 1 pause
