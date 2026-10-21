@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\CampusNetAutoLogin\CampusNet-AutoLogin.ps1" -ForceReauth
pause
