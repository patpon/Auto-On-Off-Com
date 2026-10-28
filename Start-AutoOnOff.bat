@echo off
rem Opens the Auto On/Off settings window (asks for Administrator permission)
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0AutoOnOff.ps1"
