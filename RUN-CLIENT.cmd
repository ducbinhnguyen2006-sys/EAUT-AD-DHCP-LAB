@echo off
setlocal
cd /d "%~dp0"

echo.
echo ==========================================
echo       EAUT AD DS - CLIENT MASTER SHELL
echo ==========================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0START-CLIENT.ps1"

set "RESULT=%ERRORLEVEL%"
echo.
if not "%RESULT%"=="0" (
    echo [ERROR] Client Shell failed. Exit code: %RESULT%
) else (
    echo [SUCCESS] Client Shell completed.
)

echo.
pause
exit /b %RESULT%