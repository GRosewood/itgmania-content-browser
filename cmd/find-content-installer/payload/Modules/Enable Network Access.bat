@echo off
REM One-time setup for the SMO Find Content module: allows ITGmania to reach
REM stepmaniaonline.net. Close ITGmania first, then double-click this file.
REM The actual edit is in "Enable Network Access.ps1" next to this file - open
REM it in any text editor to read exactly what it changes before running.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Enable Network Access.ps1"
