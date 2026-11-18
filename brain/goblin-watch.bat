@echo off
REM GoblinMind brain watcher - keeps GoblinMind_Data\Data.lua fresh
REM (merges your auction-book scans + ledger into the price model)
REM and files staged bug reports from the addon.
REM
REM Needs Python 3.x on PATH. Leave this window open while playing;
REM close it to stop the watcher.
cd /d "%~dp0"
REM Inside a WoW install (.../Interface/AddOns/<addon>/brain/) the
REM 'self' feed derives every path from the script location — no
REM feeds.json needed. In the dev tree that check would exit with an
REM error, so fall back to the named dev feed.
REM NOTE: no trailing backslash in the pattern — \" escapes the
REM closing quote in CommandLineToArgvW, so findstr searched for a
REM literal quote and every install took the dev-tree branch.
echo %~dp0 | findstr /i /c:"\Interface\AddOns" >nul
if errorlevel 1 (
	echo Dev tree detected - 'self' feed needs a WoW install; using 'forever' feed from feeds.json
	python goblin_brain.py watch forever -v --feed book
) else (
	python goblin_brain.py watch self -v --feed book
)
echo.
echo Watcher exited. Reopen this file to restart it.
pause
