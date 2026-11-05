@echo off
setlocal
chcp 936 >nul
title SSHD Bridge Kit

net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator permission...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $p = Start-Process -FilePath '%~f0' -Verb RunAs -PassThru -Wait; exit $p.ExitCode } catch { exit 1 }"
    if errorlevel 1 (
        echo.
        echo [ERROR] Administrator permission was not granted.
        echo Right-click install.cmd and choose "Run as administrator".
        pause
    )
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-sshd.ps1" %*
set RC=%ERRORLEVEL%

if not "%RC%"=="0" (
    echo.
    echo [ERROR] Setup exited with code %RC%.
    echo See the log and result file in this folder.
    pause
)
exit /b %RC%
