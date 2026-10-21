@echo off
chcp 65001 >nul
title 校园网自动重连 - 卸载
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-CampusNet-AutoLogin.ps1"
echo.
pause
