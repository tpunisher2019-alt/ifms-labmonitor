@echo off
title IFMS LabMonitor Python - Instalacao
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-windows.ps1"
if errorlevel 1 echo Instalacao nao concluida. Verifique o erro acima.
pause
