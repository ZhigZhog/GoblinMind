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
  base-32 encoded values (NOT 36 — see the decoder note below), **non-atomic writes** (debounce before parse).
- Brain sync: the **canonical watcher runs from the installed
  addon** — `E:\...\AddOns\GoblinMind\brain\goblin_brain.py watch
  self -v --feed book` — so `brain.log`, `book_history.json`, and
  `filed_bugs.json` live in the mod dir, not the dev tree. `watch
  self` derives every path from the script location (no feeds.json
  needed — the release never ships one). `goblin-watch.bat` is
  dual-mode: inside `...\Interface\AddOns\` it runs `watch self`,
  anywhere else (dev tree) it falls back to `watch forever`.
  `scripts\brain-watch.bat` / `watch forever` remain the dev feed —
  the in-house feed. It re-emits `GoblinMindDB` on
  BOTH triggers: SavedVariables flush (/reload, logout → newest book
  wins per item, ledger sums across chars) AND settled AppData
  writes (TSM desktop push → backend refresh folds into the merge —
  see TSM-merge rule below). `--feed tsm` switches back to the
  legacy AppData-only pipeline (20s settle on non-atomic writes).
  `python brain\goblin_brain.py emit <AppData.lua> <Data.lua>`
  remains as the manual TSM path.
- **Realm config**: each feed in `feeds.json` can pin
  `"realm": "Normal-Alliance"` — the TSM AppData scope to consume.
  `tsm_items(chunks, realm)` filters non-region chunks to that scope
  (cross-realm pollution guard); `Forever-US` region chunks always
  pass. Scope names DON'T match the addon's `GM.Scope()` — TSM
  normalizes realm names its own way (`Normal-Alliance` vs
  `CAMWOWUS1Realm5PvE-Alliance`); `cmd_book` folds the configured TSM
  scope into every book scope sharing its **faction suffix**, and a
  TSM scope with no same-faction book still emits under its own
  name (reachable via the flat top-level `items` mirror).
- **TSM-backend merge precedence** (per scope, inside `cmd_book`):
  TSM-only fields (`hist`/`recent`/`rmkt`/`rhist`/`rsale`/`rsalep`/
  `reset`) always come from the feed; book-only fields (`mbx`/`n`)
  always come from scans; shared fields (`mb`/`sup`/`p`/`mkt`/`vel`)
  follow freshness — fresher **book** (`latest_t >= realmAge`) wins
  them outright, fresher **feed** wins but book values still fill
  gaps where the feed has nothing for that item. Scope `dataAge` =
  `max(book t, realmAge)`. This is what the user meant by "backend =
  source of truth when most current, active full scan = authority
  when current."
- **Panel header collisions**: `ColPanel`/`Panel` put a `count`
  fontstring at TOPRIGHT — anything else anchored TOPRIGHT (paging
  buttons, a title repositioned to share a search row) sits ON it.
  Recipe/member/category stats belong on the panel's bottom hint
  line when the header is crowded; member titles get a width cap
  (`SetWidth` + `SetWordWrap(false)`) so long text clips instead of
  overrunning the count. CraftingUI recipe rows: name 18..186,
  profit 190..258, `can` 262..320, qbtn right-anchored — don't
  shrink these gaps.
- **Base Group = implicit container**: `GetOps` resolves ungrouped
  items through `Merged("Base Group")` (ops coverage is automatic —
  default Default ops apply to everything). The GroupsUI members
  panel lists ungrouped items under Base Group as VIEW-layer only —
  never write 7000 implicit members into the SV; `IterateItems`
  stays explicit-only (ExportString/Banking loops depend on it).
  Implicit member rows hide the x — removal = catalogue assign.
- **Ship boundary**: `brain/feeds.json`, `brain/brain.log`,
  `brain/filed_bugs.json`, `brain/book_history.json` are local-only
  (untracked + ignored). `feeds.example.json` is the template.
  SavedVariables live in WTF — never inside the addon folder — so
  personal groups/settings can't ship by construction.
  `addons/GoblinMind_Data/Data.lua` IS tracked on purpose: it's the
  generated data payload, not personal settings.
- **`GM.AH.BookLive()`** (AH.lua) is the in-game half of that rule:
  `BookAge() < DataAge()` — freshest source wins. Every "is the book
  fresh enough" decision gate goes through it (tooltip source labels
  + `BookMin`, auctioning `cheapest` + sync-scan fast paths,
  MyAuctions stale warning). Do NOT write `BookAge() < 300`-style
  fixed thresholds for source selection — a 40m backend beat a 7h
  book and the fixed gate still picked the book (the bug that
  prompted this). Dedup gates like `BookAge() < 30` ("don't rebuild
  a just-built book") are a different semantic — keep them fixed.
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
  `Startup\goblinmind-brain-watch.bat` — launches the INSTALLED
  copy (`AddOns\GoblinMind\brain\`, `watch self`) in a titled
  minimized console; `pythonw` + `&`/`disown` also works for a
  session-local watcher. The watcher **self-restarts when
  `goblin_brain.py` changes on disk** (stats own mtime each poll,
  respawns via `subprocess.Popen` + `os._exit` — `execv`/`spawnv`
  split `C:\Program Files\` on Windows). Deploy = copy the file
  over; no manual restart needed.
- **Crowdsource backend (`brain\goblin_server.py`)**: persistent
  merged-book service on `127.0.0.1:8765` (binds `0.0.0.0` — LAN
  needs a firewall rule for TCP 8765). Endpoints: `/v1/register`,
  `/v1/upload`, `/v1/book?scope=`, `/v1/health`, `/v1/scopes`.
  `/v1/health` also lists installs (name, attributed scopes, upload
  count, last-upload `t`); `/v1/scopes` is the open scope list that
  `install.py` offers as numbered choices. SQLite beside the
  script; newest-upload-wins per item, 200 uploads/install/scope,
  10 uploads/10min rate limit, 7-day staleness cutoff + hourly GC
  + weekly VACUUM, client-claimed `t` clamped at `now` (can't pin
  the book with a
  future date). Auto-starts via `Startup\goblinmind-server.bat`
  from the installed brain dir; **self-restarts on file change**
  like the watcher. The watcher pulls on a 15m cadence (remote
  books marked `remote: True` — never re-uploaded) and uploads
  only genuinely newer local books. Peer upload → merge → pull →
  emitted DB verified end-to-end. Config: `feeds.json` `backend`
  block (`url`, `name`, `scopes`, `poll_minutes`, `upload`, `key`).
  **Trust model**: `goblin_server.json` beside the server holds
  `install_secret` — when set, `/v1/register` requires it as
  `key` in the body (constant-time compare, lazy-read so rotation
  needs no restart); absent = open registration (trusted LAN).
  Re-registering an existing name re-keys that row (no zombie
  installs on reinstall). The host hands the secret to trusted
  installs out-of-band; installer flag is `--key`. `--host`
  auto-generates the secret (writes `goblin_server.json` when
  missing) and prints the LAN URL + key to share.
  The brain records the health install-count as
  `api_state.backend.peers` → `GoblinMindDB.backend.peers` →
  `/goblin status` shows "N installs". `install.py` probes
  `/v1/health`+`/v1/scopes` before writing config — bad IP or a
  closed firewall is caught at install, not at first pull.
  **Tests**: `python brain\test_server.py` — in-process server on an
  ephemeral port + temp DB; 36 checks over register/auth/cleaning/
  merge/cutoff/GC/rate-limit/key-gate/scopes/health-detail.
  Known wart it documents:
  the rate bucket increments before payload validation, so
  malformed uploads still burn quota.
  The watcher also scans `WTF\Account\*\SavedVariables\GoblinMind.lua`
  each poll for staged bug reports (`gm-<ts>-<n>|<hex>` strings in
  `GoblinMindSettings.bugReports`), files them to GitHub issues
  (repo `ZhigZhog/GoblinMind`; token pulled from `git credential fill`
  — no stored secret), records ids in `brain\filed_bugs.json`, and
  re-emits so `GoblinMindDB.filedBugs` lets the addon clear them.
  Manual one-shot: `python brain\goblin_brain.py bugs <AppData> <out...>`.
  In-game entry: `/goblin bug` AND the settings BUG REPORT button
  both open the one window (`BugReport.lua` — diagnostics block +
  SELECT ALL / SCREENSHOT / FILE REPORT / ISSUES↗). FILE REPORT
  stages via `GM.StageReport` (exported from Settings.lua — hex `title|payload` into `GoblinMindSettings.bugReports`). There is
  no second dialog; keep it that way.
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
  **Cross-source sanity bound (book merge)**: a book-computed
  `p`/`mkt` diverging >25x from the TSM feed's `mkt`/`hist` for
  the same item is treated as a poisoned/stale sample and
  dropped (TSM's number kept). Found when item 8120 emitted
  p=8e9 copper from a stale mean while mb/hist/recent were
  sane — divergence that large is a data bug, never a market.

- Layout: `brain\` (Python emit/watch CLI) · `addons\GoblinMind\`
  (shim addon, scaffolded — TSM-styled UI) · `addons\GoblinMind_Data\`
  (generated-data addon — `GoblinMindDB` from `goblin_brain.py emit`) · `scripts\`
  (`sync-addons.bat` robocopy-deploys into the AddOns dir).
- **Release packaging**: always `python scripts\package-release.py
  <version>` → `dist\GoblinMind-<version>.zip`. The zip MUST ship the
  brain as `GoblinMind/brain/{goblin_brain.py, goblin-watch.bat}`
  (same layout `sync-addons.bat` deploys — `watch self` derives the
  install root from it). An addons-only zip is broken — v0.2.0's first
  upload missed it. Release flow: merge → bump `## Version:` in both
  .tocs → package → tag `v<version>` → `git push origin main
  --follow-tags` → create the GitHub release via REST with the zip
  attached (token via `git credential fill`; the MCP is read-only).
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
    multicraft path — **`CraftRecipe(count>1) is squelched on this
    client** (pcall succeeds, no cast, "interface action failed";
    verified live 2026-11-15). A stack runs as a CHAIN: one
    `CraftRecipe(id,1)` per click, then each
    `UNIT_SPELLCAST_SUCCEEDED` fires the next link (0.15s gap —
    the client can still read "casting" in the same frame; castGUID
    dedupes SUCCEEDED+CHANNEL_STOP doubles). qty=1 works from
    insecure context (craftprobe ran it from a slash command) so
    event-driven links are legal. `C.craftChain` aborts on
    FAILED/INTERRUPTED/TRADE_SKILL_CLOSE/a dead link; a second
    `C.Craft` while one runs returns "already crafting". The
    `pendingCast` watchdog (UNIT_SPELLCAST_START within 0.6s)
    reports dead calls; `pendingOpenCraft` retries the post-open
    craft 3× at 0.6s and expires after 4s (a blocked cast left it
    firing on unrelated opens). **`C.LineOpenFor` treats EMPTY recipe
    enumerations as inconclusive, not "closed"** — `GetAllRecipeIDs`/
    `GetFilteredRecipeIDs` are partially stubbed and an empty table
    can't distinguish dead enumeration from a dead line; arming the
    OPEN overlay on a false negative made the cast toggle the live
    line shut (the open-sound/close-sound freeze). Fallback order:
    non-empty list → tracked `C.lastProf` (Scan sets it per-recipe,
    `TRADE_SKILL_CLOSE` clears it) → `ProfessionsFrame:IsShown()`
    (a parked frame stays shown while the line is live) → permissive.
    `CraftingUI`'s `OnHide` calls `CloseTradeSkill` ONLY on a
    deliberate close (`ui.closing` — X button / toggle-off); tab
    swaps and the UISpecialFrames ESC sweep must keep the session.
    Actual
    crafting progress is tracked by listening to
    `UNIT_SPELLCAST_SUCCEEDED`/`CHANNEL_STOP` (spellID == recipeID):
    each finished cast decrements `queue[spellID]` and ticks
    `step.crafted` on the active plan note step. `CraftEnchant`/
    `CraftSalvage`/`IsRecipeRepeating`/`RecraftRecipe` also exist in
    the namespace; classic `DoTradeSkill`/`DoCraft`/`GetCraftInfo`
    globals are all nil — the client is purely retail-shaped here.

    `AUCTION_CANCELED` fires once PER LISTING a
    `ReplicateItems` stream replaces — a full scan = thousands
    of events. Never surface it raw; gate on `GM.AH.Busy()` +
    `GM.AH.cancelMute` (8s tail set in both book-finish paths).
    `GetTradeSkillLineForRecipe(recipeID)` exists (TSM marks it
    retail-only and never calls it on Forever) and returns
    `(skillLineID, "Profession Name", rootSkillLine)` — the
    authoritative per-recipe profession lookup; `GetTradeSkillLine`
    and `GetBaseProfessionInfo` are dead ends (absent / zero-table).
  - **TGA pipeline**: hand-written encoder in the unmatte script —
    uncompressed 32-bit, top-down rows + `0x28` descriptor (matches
    TSM/EllesmereUI convention; the client honors both `0x08`/`0x28`).
    **Minimap icon source is `WoWVault\GoblinMindIcon.png`** →
    regenerate `addons\GoblinMind\Media\chrome-gear.tga` (65×65,
    LANCZOS, RGBA→BGRA, same header spec) — referenced by
    `Minimap.lua`. Vault PNG is gitignored like the rest of
    `WoWVault\`; the .tga is the tracked artifact.
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
  - **AppData value encoding is BASE-32, not 36** (verified against
    TSM's own `UnpackData` — `tonumber(v,32)`, >6-char tokens split as
    `hi*2^30 + lo` since Lua's tonumber tops out at 32 bits). All
    non-itemString row fields decode this way, INCLUDING digit-only
    tokens ('13' = 35, not thirteen); `itemString` itself is decimal.
    `_atom` must keep `[0-9A-Z]+` tokens as strings — `float()` reads
    '6E8' as 6e8 scientific notation, which was the source of the
    billion-scale tooltip prices. `b32()` in the brain decodes; never
    reintroduce an int()/float() fast-path for bare tokens.
  - **Replicate time-left**: `C_AuctionHouse.GetReplicateItemTimeLeft`
    isn't trustworthy on Forever — `NormTl` (AH.lua) normalizes all
    shapes: small ints 0-4 are the bucket enum (Short/Medium/Long/
    VeryLong -> 30m/2h/12h/48h seconds), numbers past the 48h cap are
    misreads -> nil, tables get probed for `seconds`/`timeLeftSeconds`/
    `timeLeft`. Fallback: the tuple itself carries timeLeft at
    `buyIdx - 3` in both known layouts.
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
      (`GetOwnedAuctionInfo.buyout` per-item too). Replicate `bid`
      is inferred at `buyIdx+1` (same +1 shift) — number-typed
      guard drops it if the layout differs; `GetReplicateItemTimeLeft`
      is guarded (may not exist). Item-search asks carry
      `bid`/`minBid`/`tl` (`timeLeftSeconds`). `Execute kind="bid"`
      fires `PlaceBid(auctionID, lotBid)` — a buy is just
      bid-at-buyout. SniperUI: clicks defer 0.35s so a second tap
      upgrades to the +1c `BidHit` before protected calls fire;
      `h.wantBid` survives an in-flight BuyHit scan.
    - Owned-auction `buyout` is **per-item** (Inventory.auctions) —
      never divide by `a.qty`; the Dashboard undercut check and
      CancelScan compare it directly against per-item `mbx`/cheapest.
    - **`QueryOwnedAuctions` takes a sorts table** — TSM passes
      OWNER_SORTS_TABLE ({Name,Price} via Enum.AuctionHouseSortOrder),
      Syndicator passes {}. A BARE call inside pcall fails silently →
      OWNED_AUCTIONS_UPDATED never fires → "no auctions up". Same for
      `QueryBids(sorts)` → `BIDS_UPDATED`. Owned-auction info table:
      itemKey.itemID/auctionID/quantity/bidAmount/buyoutAmount/bidder
      (GUID)/status/timeLeftSeconds. `GetAuctionInfoByID(auctionID)`
      exists (Syndicator uses it post-PlaceBid). Bids results API
      (GetNumBids/GetBidInfo) is probed at runtime — unverified.
      `AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION` delivers
      (notification, _, auctionID); Enum.AuctionHouseNotification has
      AuctionOutbid/AuctionWon/BidPlaced/AuctionRemoved/AuctionSold/
      AuctionExpired. Item-search `owners[]` sentinels: "player" = own
      listing, "" = redacted — translate (TSM: player→UnitName, ""→"?").
    - **Owned-auction identity is unstable**: `GetOwnedAuctionInfo`'s
      `auctionID` churns across enumerations and is sometimes absent —
      keying `auctionCache` by it logged one posted auction as ~17
      "post" txns (verified 2026-11-15 SV inspection). The cache keys
      by fingerprint `"itemID:qty:buyout"` instead (`n` counts identical
      twins); real aid/idx live on the entry for `CancelAuction`, and
      `GM.Inventory.OwnedByKey(key)` resolves fp/aid/idx. Ghost rows
      (same aid twice) are skipped, sold/history rows filtered only
      when some row reports `status==0`, and empty snapshots must
      repeat before vanish processing (mid-requery reads can be 0).
    - `GetCommoditySearchResultInfo` can return **polluted rows for
      non-commodity itemIDs** (cloth-shaped 2c lots for a bag). Only
      consume commodity results when the item search returns nothing.
    - **Protection blocks bypass `pcall`**: calling a secure Blizzard
      function (`LaunchURL`, `Screenshot`) from addon code trips
      `ADDON_ACTION_BLOCKED` + the disable/ignore dialog — not a Lua
      error. Gate with `type(f) == "function" and not
      issecurefunction(f)` before calling optional client functions.
    - **Mail flag/inbox snapshot only move on a server header push**:
      `HasNewMail` and the inbox stay stale for seconds after
      `AutoLootMailItem` loots — call `CheckInbox` ~0.7s after loots
      (debounced, one in flight) to drop the new-mail icon promptly,
      and again after `MAIL_SHOW` since pending mail lands late.
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
- Item targeting gesture is **Shift+click while the plan window is
  open** (`ItemInput.lua`). `HandleModifiedItemClick` is **REPLACED**
  (wrapped, original called through for unclaimed clicks) — the
  shared funnel Baganator, EllesmereUIBags, and Blizzard's handlers
  delegate to. Returning true is load-bearing: callers check it before
  native follow-through, so claimed clicks suppress Baganator's
  StackSplitFrame / Blizzard's split — a `hooksecurefunc` post-hook
  can't suppress, it runs after the dialog opens. Per-handler globals
  like `ContainerFrameItemButton_OnModifiedClick` don't reliably
  exist/fire on this client (Baganator replaces the bag buttons).
  `SetItemRef` is hooked separately for chat links (may not delegate
  to the funnel here). The IsShown gate keeps bare
  shift+click-for-linking from popping the planner.
- Not yet registered on the Codebase Map (project started 2026-11-11,
  post-closure).
