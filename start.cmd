@echo off
title Elite Dangerous Carrier Jump Tracker
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0carrier-watch.ps1" %*
endlocal
