@echo off
chcp 65001 >nul
title FlowSwitch 智能体检
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\SmartPatrol.ps1" -Fix
echo.
pause
