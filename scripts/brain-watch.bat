@echo off
title GoblinMind Brain
REM GoblinMind data watcher — in-house feed: re-emits GoblinMindDB
REM whenever the SavedVariables file flushes (/reload, logout),
REM merging every character's book + ledger on the account.
REM Feed names resolve via brain\feeds.json — "forever" expands to
REM that client's AppData path, SV root, and both output paths.
REM --feed tsm restores the old TSM AppData pipeline.
REM -v = verbose (heartbeats, per-item skip reasons).
REM Full log also lands in brain\brain.log (rotating, 2 MB x2).
REM Leave this window open while playing.
python "D:\WoW Mods\brain\goblin_brain.py" watch forever -v --feed book
pause
