@echo off
REM GoblinMind brain watcher - keeps GoblinMind_Data\Data.lua fresh
REM (merges your auction-book scans + ledger into the price model)
REM and files staged bug reports from the addon.
REM
REM Needs Python 3.x on PATH. Leave this window open while playing;
REM close it to stop the watcher.
cd /d "%~dp0"
python goblin_brain.py watch self -v --feed book
echo.
echo Watcher exited. Reopen this file to restart it.
pause
