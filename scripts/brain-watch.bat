@echo off
REM GoblinMind data watcher — re-emits GoblinMindDB whenever the TSM
REM desktop app drops a fresh AppData.lua. Emits to the repo copy AND
REM the deployed addon so /reload picks it up in-game.
REM Leave this window open while playing.
python "D:\WoW Mods\brain\goblin_brain.py" watch ^
  "E:\Battle.net\World of Warcraft\_forever_\Interface\AddOns\TradeSkillMaster_AppHelper\AppData.lua" ^
  "D:\WoW Mods\addons\GoblinMind_Data\Data.lua" ^
  "E:\Battle.net\World of Warcraft\_forever_\Interface\AddOns\GoblinMind_Data\Data.lua"
pause
