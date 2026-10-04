@echo off
chcp 65001 >nul
title FlowSwitch 智能体检
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\SmartPatrol.ps1" %*
echo.
pause
