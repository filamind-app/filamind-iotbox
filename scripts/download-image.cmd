@echo off
REM ---------------------------------------------------------------------
REM  download-image.cmd  --  double-clickable wrapper for Windows users
REM
REM  Usage:
REM    download-image.cmd                 latest release into .\iotbox-image\
REM    download-image.cmd v1.0.0          specific tag
REM    download-image.cmd v1.0.0 D:\out   custom output folder
REM
REM  Internally invokes scripts\download-image.ps1 with execution policy
REM  bypass so users don't need to mess with Set-ExecutionPolicy.
REM ---------------------------------------------------------------------

setlocal

set "VERSION=%~1"
if "%VERSION%"=="" set "VERSION=latest"

set "OUTDIR=%~2"
if "%OUTDIR%"=="" set "OUTDIR=.\iotbox-image"

set "SCRIPT=%~dp0download-image.ps1"
if not exist "%SCRIPT%" (
    echo ERROR: download-image.ps1 not found next to this .cmd file.
    echo Expected at: %SCRIPT%
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -File "%SCRIPT%" -Version "%VERSION%" -OutputDir "%OUTDIR%"
exit /b %ERRORLEVEL%
