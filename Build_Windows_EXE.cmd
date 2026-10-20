@echo off
echo ============================================================
echo  Webiz Inventory Agent - EXE Builder
echo ============================================================
echo.

rem Real values come from webiz_config.json (git-ignored). The repo .ps1 has placeholders only.
if not exist "%~dp0webiz_config.json" (
    echo ERROR: webiz_config.json not found. Copy webiz_config.example.json and fill it in.
    pause
    exit /b 1
)

echo [1/4] Installing ps2exe module (if not already installed)...
powershell -ExecutionPolicy Bypass -Command ^
    "if (-not (Get-Module ps2exe -ListAvailable)) { Install-Module ps2exe -Force -Scope CurrentUser -Repository PSGallery }"

if %errorlevel% neq 0 (
    echo ERROR: Failed to install ps2exe. Check internet connection or run as admin.
    pause
    exit /b 1
)

echo.
echo [2/4] Stamping configuration into a temporary copy...
if not exist "%~dp0dist" mkdir "%~dp0dist"
powershell -ExecutionPolicy Bypass -NoProfile -Command ^
    "$c = Get-Content '%~dp0webiz_config.json' -Raw | ConvertFrom-Json;" ^
    "if (-not $c.apps_script_url.StartsWith('https://script.google.com/') -or $c.agent_token.Length -lt 32) { Write-Error 'Invalid webiz_config.json'; exit 1 }" ^
    "$s = [IO.File]::ReadAllText('%~dp0WebizInventory_Windows.ps1');" ^
    "$s = $s.Replace('__WEBIZ_APPS_SCRIPT_URL__', $c.apps_script_url).Replace('__WEBIZ_AGENT_TOKEN__', $c.agent_token);" ^
    "[IO.File]::WriteAllText('%~dp0dist\_stamped_WebizInventory_Windows.ps1', $s, (New-Object Text.UTF8Encoding $true))"

if %errorlevel% neq 0 (
    echo ERROR: Could not stamp configuration. Check webiz_config.json.
    pause
    exit /b 1
)

echo.
echo [3/4] Compiling to EXE...
powershell -ExecutionPolicy Bypass -Command ^
    "Invoke-ps2exe" ^
    "-InputFile '%~dp0dist\_stamped_WebizInventory_Windows.ps1'" ^
    "-OutputFile '%~dp0dist\WebizInventory_Windows.exe'" ^
    "-NoConsole" ^
    "-STA" ^
    "-Title 'Webiz Inventory Agent'" ^
    "-Description 'Webiz device inventory check-in agent'" ^
    "-Company 'Webiz'" ^
    "-Version '1.0.0.0'"

set BUILD_ERR=%errorlevel%
del "%~dp0dist\_stamped_WebizInventory_Windows.ps1" >nul 2>&1

if %BUILD_ERR% neq 0 (
    echo ERROR: Compilation failed. See errors above.
    pause
    exit /b 1
)

echo.
echo [4/4] Done!
echo.
echo   Output: %~dp0dist\WebizInventory_Windows.exe
echo.
echo   Distribute WebizInventory_Windows.exe to employees INTERNALLY only.
echo   Note: ps2exe output is NOT encrypted - the endpoint token can be extracted.
echo   Never commit the EXE to the public repo.
echo.
pause
