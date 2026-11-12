# WoW Mods — agent notes

Workspace for **GoblinMind**: an out-of-game price model + in-game
shim addon riding on TradeSkillMaster in phase 1, migrating to a
self-owned Blizzard-API pipeline later.

- **All notes live in `WoWVault\`** (Obsidian vault). Read
  `WoWVault\phase-1-architecture.md` first; `WoWVault\code-notes-alpha.md`
  is the complete v0.1 functional map; `WoWVault\tsm-subsumption-plan.md`
  is the 14-part path to full TSM replacement; `WoWVault\phase-1-implementation.md`
  is the Phase-1 (spine) megaplan; theme reference is
  `WoWVault\tsm-theme-palette.md`.
- Target client: `E:\Battle.net\World of Warcraft\_forever_`
  ("Forever" flavor, **interface `16001`** — 1.60.x; modern-era API set:
  AppData `NON_COMMODITY` tags confirm `C_AuctionHouse` exists).
- Live data source: `...\AddOns\TradeSkillMaster_AppHelper\AppData.lua`
  — line-per-chunk `LoadData(tag, scope, [[return {...}]])` format,
  base-36 encoded values, **non-atomic writes** (debounce before parse).
- Layout: `brain\` (Python service, not built yet) · `addons\GoblinMind\`
  (shim addon, scaffolded — TSM-styled UI) · `addons\GoblinMind_Data\`
  (generated-data addon, stub until the emitter exists) · `scripts\`
  (`sync-addons.bat` robocopy-deploys into the AddOns dir).
- UI rule: match TSM's default theme — palette + fonts in
  `addons\GoblinMind\Theme.lua`, fonts referenced from TSM's Media dir.
- Client quirks (verified 2026-11-11):
  - **No `SetBackdrop`** on frames — `GM.Panel` uses fill texture + 1px
    edge strips instead. Don't use backdrops anywhere.
  - **Junctions/symlinks not honored for .lua loading** — the addon list
    reads .toc through them but file loads fail silently. Deploy = copy
    (`scripts\sync-addons.bat`), never mklink.
  - `/gm` appears shadowed/dead — primary commands are `/goblinmind`
    and `/goblin`.
  - Guard modern APIs: `TooltipDataProcessor` (HookScript fallback in
    Tooltip.lua), `C_Container` (legacy `GetContainerItemInfo` fallback
    in AH.lua), `C_Timer` (`GM.After` shim). `pcall` every
    `RegisterEvent` — an unknown event name kills the rest of a file's
    load.
  - **Chat links are nonstandard**: `|cnQ|Hitem:data…h[Name]|h|r` — quality-color
    prefix (`|cnQ`, not `|cff9d9d9d`) and no `|` before the `h[` name delimiter.
    Parse item IDs with `item:(%d+)` anywhere; extract post-link text via
    `%b[]` + strip trailing `|h|r` (see `Core.lua` price handler).
- Hard rule: in-game actions are click-per-step only — one protected
  `C_AuctionHouse` call per hardware event. ToS boundary is documented
  in the design doc §8.
- Alt+Click conflict: TSM captures Alt+Click for its own UI — our
  alt-click capture in `ItemInput.lua` may be shadowed/double-fire.
  Accepted for phase 1; re-test and possibly remap at the TSM
  replacement milestone (open question §10.6 in the vault doc).
- Not yet registered on the Codebase Map (project started 2026-11-11,
  post-closure).
