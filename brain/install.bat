@echo off
REM GoblinMind installer — sets up feeds.json (backend feed) and
REM Startup autostart for the brain watcher. Run once after
REM extracting the addon zip into Interface/AddOns/.
cd /d "%~dp0"
python install.py %*
if errorlevel 1 (
	echo.
	echo Python 3.x is required on PATH. Install from python.org
	echo ^(check "Add python.exe to PATH" during setup^), then rerun.
)
echo.
pause
