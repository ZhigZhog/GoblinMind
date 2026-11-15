@echo off
REM Deploy GoblinMind addons into the _forever_ client as real directories.
REM Junctions/symlinks are NOT honored for .lua file loading on this client —
REM the addon list reads the .toc but file loads fail silently. Always copy.
set "WOW=E:\Battle.net\World of Warcraft\_forever_\Interface\AddOns"
set "SRC=D:\WoW Mods\addons"

if not exist "%WOW%" ( echo AddOns dir not found: %WOW% & exit /b 1 )

for %%A in (GoblinMind GoblinMind_Data) do (
	robocopy "%SRC%\%%A" "%WOW%\%%A" /MIR /NFL /NDL /NJH /NJS >nul
	if errorlevel 8 ( echo FAILED %%A ) else ( echo synced %%A )
)

REM Brain rides inside the addon folder so `watch self` can derive
REM the install root — same layout the release zip ships.
robocopy "D:\WoW Mods\brain" "%WOW%\GoblinMind\brain" goblin_brain.py goblin-watch.bat /NFL /NDL /NJH /NJS >nul
if errorlevel 8 ( echo FAILED brain ) else ( echo synced brain )
