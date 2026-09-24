@echo off
setlocal EnableExtensions
set "QQ_VERSION=2026.09.24.6.1"
set "RECOVER=%TEMP%\quillgeist-lite-emergency-recover.py"
set "URL=https://raw.githubusercontent.com/clintkosh/clintware-site/52b3ad95f78e5e735bef66f988171280fcce785c/quillgeist-lite/tools/emergency_recover.py"

echo RECOVERY // fetching Quillgeist Lite Python self-repair %QQ_VERSION%
curl.exe -fsSL "%URL%" -o "%RECOVER%"
if errorlevel 1 (
  echo ERROR // could not download Python recovery
  exit /b 1
)

where py.exe >nul 2>&1
if not errorlevel 1 (
  py.exe -3 "%RECOVER%"
  exit /b %ERRORLEVEL%
)

where python.exe >nul 2>&1
if not errorlevel 1 (
  python.exe "%RECOVER%"
  exit /b %ERRORLEVEL%
)

echo ERROR // Python 3 was not found. Quillgeist Lite cannot run the deterministic recovery.
exit /b 1
