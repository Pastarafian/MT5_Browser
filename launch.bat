@echo off
color 0A
title MT5 Browser Engine
echo ==================================================
echo MT5 Browser - Playwright Headless Chromium Engine
echo ==================================================
echo.

cd /d "%~dp0python"
echo [i] Starting Python Playwright Server...
python browser_server.py

if %errorlevel% neq 0 (
    echo.
    color 0C
    echo [ERROR] The browser engine crashed or failed to start.
    pause
)
