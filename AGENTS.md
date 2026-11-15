# WoW Mods — agent notes

Workspace for **GoblinMind**: a standalone price-model + in-game
auction/crafting addon. Phase 1 rode TradeSkillMaster; **Part 14
cutover (done 2026-11-15) removed the hard dependency** — addon loads
with or without TSM. Fonts vendored in `addons\GoblinMind\Media\`
(Montserrat), LibStub/LibDeflate/LibSerialize vendored in `Libs\` for
group import/export. Guarded `TSMAPI_FOUR` calls remain as optional
fallbacks (`GM.TSMMarket`, `destroy` source) and go nil without TSM.
Primary data = the in-house book feed below.

- **All notes live in `WoWVault\`** (Obsidian vault). Read
  `WoWVault\phase-1-architecture.md` first; `WoWVault\code-notes-alpha.md`
  is the complete v0.1 functional map; `WoWVault\tsm-subsumption-plan.md`
  is the 14-part path to full TSM replacement; `WoWVault\phase-1-implementation.md`
  is the Phase-1 (spine) megaplan; theme reference is
  `WoWVault\tsm-theme-palette.md`; `WoWVault\gm-api-reference.md`
  is the internal helper/widget API surface — CHECK SIGNATURES THERE
  before calling shared helpers (`GM.Label` does NOT exist; it's
  `GM.MakeFontString(parent, template, size, colorKey)`).
- Target client: `E:\Battle.net\World of Warcraft\_forever_`
  ("Forever" flavor, **interface `16001`** — 1.60.x; modern-era API set:
  AppData `NON_COMMODITY` tags confirm `C_AuctionHouse` exists).
- Live data source: `...\AddOns\TradeSkillMaster_AppHelper\AppData.lua`
  — line-per-chunk `LoadData(tag, scope, [[return {...}]])` format,
  base-36 encoded values, **non-atomic writes** (debounce before parse).
- Brain sync: `scripts\brain-watch.bat` runs `watch forever -v
  --feed book` — the in-house feed. On each SavedVariables flush
  (/reload, logout) it re-emits `GoblinMindDB` merged across every
  character's `GoblinMind.lua` on the account (newest book wins per
  item, ledger sums across chars). `--feed tsm` switches back to the
  legacy AppData pipeline (20s settle on non-atomic writes).
  `python brain\goblin_brain.py emit <AppData.lua> <Data.lua>`
  remains as the manual TSM path.
- **Feed registry (`brain\feeds.json`)**: named feeds replace raw
  paths — `{"forever": {appdata, root, out[]}}`. Any command arg
  that resolves a feed name (`watch forever`, `book forever`,
  `bugs forever`, `emit forever`) expands to that client's AppData
  path, WTF SV glob, and output list; `python goblin_brain.py feeds`
  lists them. Raw paths still work (backward compat). Emitted DBs
  carry `feed="<name>"`. **Porting to another client/realm = one
  feeds.json entry + one bat line — no code change.** Each feed's
  watcher writes only its own outputs, so multiple watchers can run
  in parallel (one per install). **Auto-starts at login** via
  `Startup\goblinmind-brain-watch.bat` (launches `pythonw`, no console);
  `pythonw` + `&`/`disown` also works for a session-local watcher.
  The watcher also scans `WTF\Account\*\SavedVariables\GoblinMind.lua`
  each poll for staged bug reports (`gm-<ts>-<n>|<hex>` strings in
  `GoblinMindSettings.bugReports`), files them to GitHub issues
  (repo `ZhigZhog/GoblinMind`; token pulled from `git credential fill`
  — no stored secret), records ids in `brain\filed_bugs.json`, and
  re-emits so `GoblinMindDB.filedBugs` lets the addon clear them.
  Manual one-shot: `python brain\goblin_brain.py bugs <AppData> <out...>`.
- **In-house feed (Part 15, live — the watcher default)**: `python
  brain\goblin_brain.py book <AppData-or-SV-path> <out...>` emits
  `GoblinMindDB` from OUR data, merging every `GoblinMind.lua` under
  `WTF\Account\*\SavedVariables\` when given the AppData path (or a
  single file when given `...\GoblinMind.lua`). Sources: persisted AH
  book (`GoblinMindSettings.book`, mb/mbx/sup/n) + ledger sells
  (`GoblinMindLedger.byChar`, sell txns → `vel` = units/day over 7d).
  The brain owns the time series in `brain\book_history.json` (14d of
  snapshots, idempotent by book timestamp); `p`/`mkt` = weighted
  trimmed mean — outliers outside [med/3, 3·med] dropped, survivors
  recency-weighted (half-life ~4d), mean trimmed 10% each end.
  Emits `source="bookfeed"`, same schema, `vendorBuy` still scraped
  from TSM's VendorSell table. Honest-nil: no samples → no price.
- Layout: `brain\` (Python emit/watch CLI) · `addons\GoblinMind\`
  (shim addon, scaffolded — TSM-styled UI) · `addons\GoblinMind_Data\`
  (generated-data addon — `GoblinMindDB` from `goblin_brain.py emit`) · `scripts\`
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
  - Guard modern APIs: bare `GetItemInfo` is NOT a global — use
    `C_Item.GetItemInfo or GetItemInfo`; `C_Item.GetItemLink` takes an
    ItemLocation, not an ID (get links via `GetItemInfo` return 2);
    `C_Item.GetItemFamily` needs a LINK for items (raw IDs return 0).
    `TooltipDataProcessor` (HookScript fallback in
    Tooltip.lua), `C_Container` (legacy `GetContainerItemInfo` fallback
    in AH.lua), `C_Timer` (`GM.After` shim). `pcall` every
    `RegisterEvent` — an unknown event name kills the rest of a file's
    load.
  - **Chat links are nonstandard**: `|cnQ|Hitem:data…h[Name]|h|r` — quality-color
    prefix (`|cnQ`, not `|cff9d9d9d`) and no `|` before the `h[` name delimiter.
    Parse item IDs with `item:(%d+)` anywhere; extract post-link text via
    `%b[]` + strip trailing `|h|r` (see `Core.lua` price handler).
  - **Draw order is oldest-on-top within a layer**: textures created
    first draw OVER later ones on the same layer+sublevel. This buried
    the chrome's BACKGROUND slices under `GM.Panel`'s `_gmBg` fill —
    fixed with explicit `SetDrawLayer` sublevels (body -7, panel chrome
    -6, `_gmBg` tint -5). Never rely on creation order for z; set
    sublevels.
  - **`SetTexCoord` signature is (left, right, top, bottom)** — not
    (l,t,r,b). Transposing silently produces 1px-column stretches that
    look like solid bands.
  - **`C_TradeSkillUI.CraftRecipe` works for qty=1** (verified
    2026-11-14 via `/goblin craftprobe`); count>1 is Blizzard's
    multicraft path — `C.Craft` attempts it and a `pendingCast`
    watchdog (UNIT_SPELLCAST_START within 0.6s) detects a dead call
    and sets `C.noBatch` → session-wide single-cast fallback. Actual
    crafting progress is tracked by listening to
    `UNIT_SPELLCAST_SUCCEEDED`/`CHANNEL_STOP` (spellID == recipeID):
    each finished cast decrements `queue[spellID]` and ticks
    `step.crafted` on the active plan note step. `CraftEnchant`/
    `CraftSalvage`/`IsRecipeRepeating`/`RecraftRecipe` also exist in
    the namespace; classic `DoTradeSkill`/`DoCraft`/`GetCraftInfo`
    globals are all nil — the client is purely retail-shaped here.
    `GetTradeSkillLineForRecipe(recipeID)` exists (TSM marks it
    retail-only and never calls it on Forever) and returns
    `(skillLineID, "Profession Name", rootSkillLine)` — the
    authoritative per-recipe profession lookup; `GetTradeSkillLine`
    and `GetBaseProfessionInfo` are dead ends (absent / zero-table).
  - **TGA pipeline**: hand-written encoder in the unmatte script —
    uncompressed 32-bit, top-down rows + `0x28` descriptor (matches
    TSM/EllesmereUI convention; the client honors both `0x08`/`0x28`).
  - **Recipe capture is event-driven**: `C_TradeSkillUI` only returns
    data for the *open* profession — `Scan()` hooks
    `TRADE_SKILL_LIST_UPDATE`/`TRADE_SKILL_SHOW`, so recipes appear as
    the player opens each tradeskill (the Blizzard "Professions" book
    counts). Profession naming on Forever (verified 2026-11-15):
    `GetBaseProfessionInfo` returns an all-zero table,
    `GetCategoryInfo` returns nothing, `GetTradeSkillLine` doesn't
    exist — but **`C_TradeSkillUI.GetTradeSkillLineForRecipe(id)`
    works** (TSM asserts it retail-only and never calls it here):
    returns `(skillLineID, displayName, rootSkillLine)` — name is
    return 2. `C.Prof(recipeID)` uses it.
  - **Item names/icons resolve asynchronously**: `GetItemInfo` returns
    nil for uncached items — use `GM.ItemName`/`GM.ItemIcon`
    (Core.lua) which call `RequestLoadItemDataByID`, and refresh via
    `GM.OnItemInfoLoaded(fn)` on `GET_ITEM_INFO_RECEIVED`.
  - **The AH book persists** in `GoblinMindSettings.book` (aggregate
    mb/mbx/sup/n only; `math.huge` round-trips through -1). Rows stay
    session-only. `AH.RestoreBook` runs on `PLAYER_LOGIN`.
  - **AH price-field semantics are NON-RETAIL** (verified 2026-11-13):
    - `C_AuctionHouse.GetItemSearchResultInfo` returns `buyoutAmount`
      **per ITEM**, not the lot total (proof: qty=147 buyout=200 →
      2s/bag, not 200c for 147 bags). `unit = price`, `total = price*qty`.
      Retail/TSM convention divides by quantity — do NOT.
    - `C_AuctionHouse.GetReplicateItemInfo` has an **extra field early
      in the tuple**: buyoutPrice is index **11** (not 10), itemID 18
      (not 17). Detect via itemID position (`buyout = itemIDidx - 7`),
      don't hardcode. `GetNumReplicateItems` returns 0 when the AH is
      closed/snapshot expired — replicate only populated after
      `ReplicateItems` + the list-update event. Replicate buyout is
      also **per-item** (unit = buyout, no `/stackSize`) — same
      convention as item-search results and owned auctions
      (`GetOwnedAuctionInfo.buyout` per-item too).
    - Owned-auction `buyout` is **per-item** (Inventory.auctions) —
      never divide by `a.qty`; the Dashboard undercut check and
      CancelScan compare it directly against per-item `mbx`/cheapest.
    - `GetCommoditySearchResultInfo` can return **polluted rows for
      non-commodity itemIDs** (cloth-shaped 2c lots for a bag). Only
      consume commodity results when the item search returns nothing.
    - `GetMouseFocus` AND `GetMouseFoci` are both gone — drop
      resolution must hit-test panes with `IsMouseOver()` (geometric
      bounds check, always present) instead of the focus API.
    - `C_MerchantFrame.GetItemInfo(idx)` is namespaced and returns a
      table (`price`, `stackCount`, `numAvailable`, `hasExtendedCost`) —
      the global `GetMerchantItemInfo` doesn't exist. `GetItemInfo`
      isn't a global either — always `C_Item.GetItemInfo`.
  - **Frame names must never equal a SavedVariable name**: SVs load at
    ADDON_LOADED (after files run) and OVERWRITE the frame global —
    `UISpecialFrames` then resolves to a plain table and Blizzard's
    `CloseSpecialWindows` crashes on `table:IsShown()`. Worse, opening
    the window re-clobbers `_G[SVname]` with the frame so the logout
    serializer can't write it = silent settings loss. (Was
    `GoblinMindSettings` frame ↔ SV; renamed frame to
    `GoblinMindSettingsFrame`. All frames get a `*Frame`/`UI` suffix.)
    `/goblin uidump` audits UISpecialFrames + UIPanelWindows for
    unresolvable entries — Forever ships ~29 retail-only names in
    `UIPanelWindows` (Garrison*/OrderHall*/Chromie*/etc.) that resolve
    NIL on this client; that's Blizzard-side noise, not ours.
  - **Container drops need a family check**: `PickupContainerItem` into a
  specialized bag (reagent bag, profession bags) fails with "That item
  doesn't go in that container". Check `ItemWillGoInBag`-style:
  `C_Item.GetItemFamily(itemID) & C_Item.GetItemFamily(equippedBagLink) > 0`,
  or `bagFamily == 0` (generic). TSM: `BagTracking.ItemWillGoInBag`.
  Bag IDs on Forever: bags 0..NUM_BAG_SLOTS+NumReagentBagSlots, bank
  bags follow for NumCharacterBankSlots, reagent bank = -3 (all via
  `Constants.InventoryConstants`, same as TSM's Container.lua).
- **Frame strata conventions** (audited across installed addons 2026-11-12):
    **windows → `HIGH` + `SetToplevel(true)`** — TSM's ApplicationFrame and
    EllesmereUI's skinned Blizzard panels both use `HIGH`; toplevel gives
    click-to-raise so windows stack with peers instead of pinning above or
    below. `MEDIUM` gets buried by the AH; `FULLSCREEN_DIALOG` (239 uses —
    options dialogs, overlays) pins above everything. `TOOLTIP` = TSM popups.
    Minimap buttons → `MEDIUM` + `SetFixedFrameStrata/SetFixedFrameLevel(true)`
    at level 8 (LibDBIcon, guarded). Child ordering = `SetFrameLevel(parent + N)`.
- **Blizzard-frame takeovers** (`FramePark.lua`, shared): never `Hide()`
  a native session frame (OnHide closes the tradeskill/merchant session
  the API calls need). `GM.FramePark.Park(pf)` collapses UIPanel attrs,
  pins at `100000,100000`, hooks `SetPoint` to re-park, and strips
  `UIPanelWindows`/`UISpecialFrames` so ESC can't reach it (a parked
  frame is still SHOWN and eats ESC). `FP.Restore` hands registrations
  + position back but never `Show()`s (session may be dead — popping a
  ghost window is a bug). Combat-locked frames defer to
  `PLAYER_REGEN_ENABLED` internally. Takeover windows each stamp a
  GOBLINMIND button on the native frame and carry a BLIZZARD UI button;
  closing ours (not wantDefault) unparks + `CloseTradeSkill`/
  `CloseMerchant` — close means close. Used by CraftingUI
  (ProfessionsFrame) and VendoringUI (MerchantFrame). Merchant API on
  Forever: `GetMerchantNumItems`/`GetMerchantItemLink` globals exist;
  `GetBuybackItemInfo(i)` → (_, _, price, qty); `BuyMerchantItem`,
  `BuybackItem`, `CanMerchantRepair`, `GetRepairAllCost`,
  `RepairAllItems(fromGuild)` all global (TSM LibTSMWoW/API/Merchant.lua).
- **Group import/export** (`Groups.lua` + GroupsUI IMP/EXP buttons):
  - TSM group paths are **backtick-separated** (`Tailoring`Bags`);
    ```` is an escaped literal comma. Ours use `/` — convert at the
    boundary (`TsmToGmPath`/`GmToTsmPath`).
  - TSM v4 export wire format = LibSerialize (stable) →
    `C_EncodingUtil.CompressString` → LibDeflate `EncodeForPrint`.
    Decode via `LibStub("LibDeflate"/"LibSerialize")` — TSM embeds both
    (vendor them at de-TSM). `Deserialize` returns `(success, values…)` —
    index past the flag when pcall-wrapping.
  - Export emits the TSM-legacy comma format (`group:Path`Sub,i:id,…`)
    which TSM itself still imports — round-trips both directions.
  - Drag-drop: custom proxy pattern (OnMouseDown arms, >6px move arms
    the drag, OnUpdate resolves target via GetMouseFocus). OnClick fires
    BEFORE the drop-resolving OnUpdate — guard clicks on `ui.drag`, not
    just a timestamp.
- Hard rule: in-game actions are click-per-step only — one protected
  `C_AuctionHouse` call per hardware event. ToS boundary is documented
  in the design doc §8.
- Alt+Click conflict: TSM captures Alt+Click for its own UI — our
  alt-click capture in `ItemInput.lua` may be shadowed/double-fire.
  Accepted for phase 1; re-test and possibly remap at the TSM
  replacement milestone (open question §10.6 in the vault doc).
- Not yet registered on the Codebase Map (project started 2026-11-11,
  post-closure).
