@echo off
setlocal enabledelayedexpansion

echo === Zenkai getapps — Windows App Enumerator ===
echo.

where dotnet >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] .NET SDK not found. Install it from:
    echo         https://dotnet.microsoft.com/en-us/download
    echo.
    echo Alternatively, install via winget:
    echo         winget install Microsoft.DotNet.SDK.9
    pause
    exit /b 1
)

echo [1/2] Restoring packages...
dotnet restore getapps.csproj
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Restore failed.
    pause
    exit /b %ERRORLEVEL%
)

echo [2/2] Building Release x64...
dotnet build getapps.csproj -c Release --no-restore
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Build failed.
    pause
    exit /b %ERRORLEVEL%
)

copy /y bin\Release\net9.0-windows\getapps.exe getapps.exe >nul

echo.
echo === Build successful! ===
echo Binary: getapps.exe
echo.
echo To export your installed apps as JSON:
echo     getapps.exe ^> apps.json
echo.
pause
