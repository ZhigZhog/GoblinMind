@echo off
title GoblinMind Brain
REM GoblinMind data watcher — in-house feed: re-emits GoblinMindDB
REM whenever the SavedVariables file flushes (/reload, logout),
REM merging every character's book + ledger on the account.
REM --feed tsm restores the old TSM AppData pipeline.
REM -v = verbose (heartbeats, per-item skip reasons).
REM Full log also lands in brain\brain.log (rotating, 2 MB x2).
REM Leave this window open while playing.
python "D:\WoW Mods\brain\goblin_brain.py" watch -v --feed book ^
  "E:\Battle.net\World of Warcraft\_forever_\Interface\AddOns\TradeSkillMaster_AppHelper\AppData.lua" ^
  "D:\WoW Mods\addons\GoblinMind_Data\Data.lua" ^
  "E:\Battle.net\World of Warcraft\_forever_\Interface\AddOns\GoblinMind_Data\Data.lua"
pause
