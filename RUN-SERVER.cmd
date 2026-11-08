@echo off
setlocal
cd /d "%~dp0"

echo.
echo ==========================================
echo       EAUT AD DS - SERVER MASTER SHELL
echo ==========================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0START-SERVER.ps1"

set "RESULT=%ERRORLEVEL%"
echo.
if not "%RESULT%"=="0" (
    echo [ERROR] Server Shell failed. Exit code: %RESULT%
) else (
    echo [SUCCESS] Server Shell completed.
)

echo.
pause
exit /b %RESULT%