@echo off
REM Deploy GoblinMind addons into the _forever_ client as real directories.
REM Junctions/symlinks are NOT honored for .lua file loading on this client —
REM the addon list reads the .toc but file loads fail silently. Always copy.
set "WOW=E:\Battle.net\World of Warcraft\_forever_\Interface\AddOns"
set "SRC=D:\WoW Mods\addons"

if not exist "%WOW%" ( echo AddOns dir not found: %WOW% & exit /b 1 )

REM /XD brain: the brain dir is synced by its own step below — mirroring
REM the addon dir must NOT wipe the watcher's runtime state (feeds.json,
REM api_state.json, api_book.json, book_history.json, brain.log,
REM goblin_backend.db, filed_bugs.json all live there and are machine-local).
REM /XF Data.lua: GoblinMind_Data\Data.lua is LIVE emit output — the dev
REM copy is a stale release artifact; deploying it over the watcher's
REM file makes the client load a day-old DB (stale sync, phantom
REM "backend not configured" popup).
for %%A in (GoblinMind GoblinMind_Data GoblinUI) do (
	robocopy "%SRC%\%%A" "%WOW%\%%A" /MIR /XD brain /XF Data.lua /NFL /NDL /NJH /NJS >nul
	if errorlevel 8 ( echo FAILED %%A ) else ( echo synced %%A )
)

REM Brain rides inside the addon folder so `watch self` can derive
REM the install root — same layout the release zip ships. Explicit file
REM list (no /MIR): runtime files the watcher/server create stay put.
robocopy "D:\WoW Mods\brain" "%WOW%\GoblinMind\brain" goblin_brain.py vendor_buy.json recipe_sources.json goblin_server.py install.py feeds.example.json goblin_server.example.json /NFL /NDL /NJH /NJS >nul
if errorlevel 8 ( echo FAILED brain ) else ( echo synced brain )
