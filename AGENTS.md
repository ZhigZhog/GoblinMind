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
  `BookAge() + 2 < DataAge()` — freshest source wins, with a 2s
  epsilon because the emit folds the book's own timestamp into
  `dataAge` (a strict `<` would let the book beat the emit that
  already contains it by one tick). Every "is the book fresh
  enough" decision gate goes through it (tooltip source labels,
  auctioning sync-scan fast paths, MyAuctions stale warning). Do
  NOT write `BookAge() < 300`-style fixed thresholds for source
  selection — a 40m backend beat a 7h book and the fixed gate
  still picked the book (the bug that prompted this). Dedup gates
  like `BookAge() < 30` ("don't rebuild a just-built book") are a
  different semantic — keep them fixed.
- **Universal source pipeline** (Core.lua `GM.ItemEntry`): the
  emitted DB row is the base, but OBSERVATION fields `mb`/`mbx`/
  `sup`/`n` are overlaid per-item from the freshest of three
  sources — live book when `BookLive()`, mesh `M` beacons
  (`GM.Mesh.LatestMB`) when newer than both book and emit, emitted
  row otherwise. Book also supplies obs fields when the emit has
  no row for the item (stale provenance beats a blank). Model
  fields (`p`/`mkt`/`hist`/`vel`/region) stay emitted — pricing is
  the brain's job. Winners are tagged `_src`/`_srcT` on the
  returned row (`"book" | "mesh" | nil`=emit); tooltips and stat
  panels must read provenance from the tag, never re-decide
  freshness locally. ALL value lookups (`ef` in Pricing, tooltip
  lines, PlanQueue stats, Inventory undercut checks) already route
  through `ItemEntry` — do not bypass it with direct `GM.AH.book`
  reads for item values.
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
  (`GoblinMindLedger.byChar`, sell txns → `vel` = units/day over 7d)
  + sale-delta events (`api_state.sales` — disappeared lot
  fingerprints between scans → market-wide `vel`/`rsale`/`rsalep`).
  **`lots` must survive browse clobbers**: `FinishBrowse` persists a
  browse book over the last replicate but keeps `bookLots`/`bookLotsT`
  (the fingerprint's own timestamp — `delta_record` reads `lotsT`,
  not book `t`). Wiping them starved the delta engine entirely —
  `api_state.sales` stayed empty and SALES/D showed only the 11
  personal-sell items. **`watch self` has no feeds.json realm**: the
  TSM→scope merge needs `tsm_faction` to fold regional stats into
  book scopes — `self_feed` reads a `realm` override from the
  installed feeds.json, and `cmd_book` auto-picks the TSM realm
  scope when exactly one exists (unmerged multi-realm = emit
  standalone, never guess). Found 2026-11-17: CAMWOW scope had 11
  vel while Normal-Alliance carried 6,144 it never absorbed.
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
  - **Deploy must never wipe brain runtime state** — `sync-addons.bat`
    mirrors the addon dirs with `/MIR /XD brain` and copies the brain's
    script files by explicit name (no purge). Before the `/XD brain`
    guard, every sync deleted the installed `brain/` contents that
    exist only on the machine: `feeds.json` (the in-game backend
    onboarding writes it!), `api_state.json`, `api_book.json`,
    `book_history.json`, `brain.log`, `filed_bugs.json`,
    `goblin_backend.db`. A wiped feeds.json emits `backend={}` → the
    onboarding popup reappears "unconfigured". Never reintroduce a
    bare `/MIR` or `/PURGE` over the brain dir. Same rule for
    `GoblinMind_Data\Data.lua` (`/XF` on the mirror): the installed
    copy is LIVE watcher output — the dev copy is a stale release
    artifact, and deploying it makes the client load a day-old DB
    (stale sync ages + phantom "not configured" popup since the old
    emit predates the backend block). Verified live 2026-11-17.
  - **Hard per-script CPU budget** — a script that runs too long
    dies with "insecure scripts exceeded execution limit"
    (attribution shows the *handler's* file, `Settings.lua:-1`, not
    the offender). Render paths must never do O(items×mats×slots)
    work synchronously: `GM.BagCount` once scanned all ~120 bag
    slots per call and `C.List` called `Inventory.Count` per mat
    per recipe → ~150k API calls per render → repeated kills at
    12fps forever. **The O(1)-by-construction contract** (verified
    live 2026-11-17): all per-item helpers are bucket-memoized —
    `BagMap`/`BankMap` (250ms), `Inventory.Count`/`Owned` (250ms),
    `ItemEntry` (250ms — shared return table, read-only), `C.List`
    (3s TTL). New helpers that need a scan must memoize on the
    same `math.floor(GetTime() * 4)` bucket — never scan
    containers/auctionCache/transactions per call, and never write
    to memoized return tables.
  - **Frame API calls can return SECRET values** (`IsShown()`,
    `GetName()` on protected/Blizzard frames): a "secret boolean/
    string" throws on ANY boolean test or table-key use while
    execution is tainted — *including after a successful pcall'd
    read* (the call succeeds, the test outside it throws). Keep the
    ENTIRE probe (read + test + use) inside one pcall; a per-frame
    secret throw is itself an fps bomb. Found 2026-11-17 when the
    perf frame-walk died at `if okS and shown`.
  - **The client autosaves ALL SavedVariables ~every 90s**, not just
    on /reload/logout — and byte-identically when nothing changed.
    Any SV-mtime watcher must dedupe on CONTENT (sha1 of file bytes),
    never mtime: an mtime trigger fires an emit every ~90s forever.
    The watcher does this in `watch_self` (`sv_signature()`);
    book emits now only run when bytes actually changed. Verified
    live 2026-11-17 — ~11s CPU emit + 2.7MB write every ~70s
    before the fix.
  - **Fontstring bounding rule** (added 2026-11-17 after the
    194-group import overflow): every `GM.MakeFontString` that can
    carry dynamic text must be bounded — `SetWidth` + `SetWordWrap(false)`
    (hard clip) or `SetMaxLines(n)` (wrapped). `SetWidth` ALONE wraps
    vertically and bleeds into the next row — width without nowrap is
    not a bound. Shared buttons (`W.Btn`/`W.ActionBtn`/`W.Segment`)
    self-bound `b.text` to `w - 8`; one-off buttons still need it.
    Preserve the anchor's alignment: LEFT-anchored gets
    `SetJustifyH("LEFT")`, RIGHT-anchored gets `RIGHT`, CENTER-anchored
    needs no justify (width alone clips evenly). Dual-anchored
    (LEFT+RIGHT) fontstrings span-bound — nowrap only. Menus/lists
    sized by content (`4 + N*18`) cap at ~14 visible rows + mousewheel
    (PopupMenu convention) — never let content size a popup.
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
  - **`C_TradeSkillUI.CraftRecipe` multicrafts — but ONLY the full
    6-arg call, ONLY from a hardware event** (verified live
    2026-11-16: `CraftRecipe(2657, 2, nil, nil, nil, nil)` from a
    slash context produced 2 Copper Bars; TSM passes the identical
    `(spellId, quantity, optionalMats, level, nil,
    applyConcentration)` shape on Forever). `CraftRecipe(id, n)`
    with just two args is silently ignored. Timer/event-callback
    calls (C_Timer, event handlers) no-op regardless — pcall
    succeeds, no cast, no error; **hardware-gating is real**, same
    as retail (why TSM is one-click-per-craft there). `/cast
    <recipe name>` does NOT work — recipes aren't spellbook spells.
    The one correct model: **one real click → one full-arg call →
    the engine auto-repeats internally for the whole batch**.
    OPEN→CRAFT is a two-click flow for the same reason — nothing
    may fire the follow-up craft for the user.
    Batch completion events: `UNIT_SPELLCAST_SUCCEEDED` fires
    PER ITEM for larger batches, separated by the real cast time
    (≈2.8s/item for Heavy Shot) — a short settle delay credits the
    batch after item #1 (the advance-after-one bug). Small batches
    may emit a single event for the whole run. Bookkeeping waits
    for engine idle (UnitCastingInfo/ChannelInfo clear + 1s since
    last event), then credits `min(bag-delta, n) − events-seen` —
    `C_Item.GetItemCount` before/after the call is ground truth;
    castGUID dedupes SUCCEEDED+CHANNEL_STOP pairs. Interrupted/
    failed clears only when the spellID matches the batch recipe
    (unrelated spell failures must not void bookkeeping).
    `C.pendingCast` + `C.WatchCast` (UNIT_SPELLCAST_START within
    0.6s) reports dead calls; `C.pendingOpenCraft` only carries the
    "click CRAFT" prompt now. **`C.LineOpenFor`/`C.LineClosedFor`
    treat EMPTY recipe enumerations as inconclusive, not "closed"**
    — `GetAllRecipeIDs`/`GetFilteredRecipeIDs` are partially
    stubbed and an empty table can't distinguish dead enumeration
    from a dead line; arming the OPEN overlay on a false negative
    made the cast toggle the live line shut (open/close loop).
    Evidence order (both directions): `C.recentOpen[recipeID]` stamp
    (survives a young <8s TRADE_SKILL_CLOSE — Forever can deliver
    SHOW(new) BEFORE CLOSE(old); lazy expiry 12s) → either enum
    proves presence, ONLY `GetAllRecipeIDs` proves absence
    (`GetFilteredRecipeIDs` honors the Blizzard frame's search
    filter — absence in a filtered subset is ambiguous) → tracked
    `C.lastProf` (Scan sets it, TRADE_SKILL_CLOSE clears; Mining↔
    Smelting alias via SpellName(2575)/SpellName(2656)) →
    `ProfessionsFrame:IsShown()` (a parked frame stays shown while
    the line is live). `CraftingUI`'s `OnHide` calls
    `CloseTradeSkill` ONLY on a deliberate close (`ui.closing` —
    X button / toggle-off); tab swaps and the UISpecialFrames ESC
    sweep must keep the session. Actual crafting progress is
    tracked by listening to `UNIT_SPELLCAST_SUCCEEDED`/
    `CHANNEL_STOP` (spellID == recipeID): each finished cast
    decrements `queue[spellID]` and ticks `step.crafted` on the
    active plan note step. `CraftEnchant`/`CraftSalvage`/
    `IsRecipeRepeating`/`RecraftRecipe` also exist in the
    namespace; classic `DoTradeSkill`/`DoCraft`/`GetCraftInfo`
    globals are all nil — the client is purely retail-shaped here.

    `AUCTION_CANCELED` fires once PER LISTING a
    `ReplicateItems` stream replaces — a full scan = thousands
    of events. Never surface it raw; gate on `GM.AH.Busy()` +
    `GM.AH.cancelMute` (8s tail set in both book-finish paths).
    `GetOwnedAuctionInfo` rows can include sold/history ghosts the
    `status` filter can't prove — bare fingerprint-count deltas
    ratchet up over a session and read as phantom ledger `post`s.
    Posts are only ledgered inside `GM.Inventory.ArmPost`'s window
    (armed by AH.Execute's post step + AUCTION_HOUSE_AUCTION_
    CREATED); vanished rows get a double-confirm (`pendingLost` —
    must stay gone one refresh) before sell/expire can ledger, so
    ghost flicker can't fake sales into the `vel` feed.
    `/goblin owndump` dumps raw rows for diagnosis.
    `GetTradeSkillLineForRecipe(recipeID)` exists (TSM marks it
    retail-only and never calls it on Forever) and returns
    `(skillLineID, "Profession Name", rootSkillLine)` — the
    authoritative per-recipe profession lookup; `GetTradeSkillLine`
    and `GetBaseProfessionInfo` are dead ends (absent / zero-table).
  - **No milling, no prospecting — not planned**: herbs and ores
    have no destroy/consume-to-mats action on Forever. Tooltip
    `P_Destroy`/`P_Convert` early-return on `GM.Gathering.IsHerb(id)`
    (herb id set in Gathering.lua); the `destroy` price source only
    consults TSM's per-item `destroy` (which encodes mill/prospect
    EV) when `DisenchantDrops(id)` is non-nil, and the tooltip line
    additionally requires `destroy > vendorSell` — mill-EV flickering
    in under the vendor price was the original bug.
  - **Item-load request/render loop (fixed 2026-11-17)**:
    `C_Item.RequestLoadItemDataByID` must be DEDUPED — every request
    produces a `GET_ITEM_INFO_RECEIVED` burst, bursts repaint
    `GM.OnItemInfoLoaded` subscribers, repaints re-render unresolved
    ids → self-sustaining request/render loop (severe fps drop until
    /reload once a window shows an id the client can't load — e.g.
    Forever's custom `25xxxx` items). `Core.lua` `ReqOnce` gates each
    id to one request per 60s; every `OnItemInfoLoaded` callback MUST
    gate its refresh on `IsShown` (the unguarded `PQ.Refresh` was the
    sink that kept the loop alive while the window was closed).
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
    **Partial-tuple trap (verified 2026-11-16 via `/goblin deprobe`)**:
    uncached items return a name-only tuple — `name` populated,
    quality/ilvl/equipLoc/classID all nil — so position-destructured
    fields look "loaded" but silently gate-check false. Worse,
    `C_Item.GetItemInfoInstant` is ABSENT. The dedicated static-data
    APIs DO work: `C_Item.GetItemQualityByID`,
    `C_Item.GetDetailedItemLevelInfo`, and (pending verify)
    `C_Item.GetItemInventoryTypeByID` + global `IsEquippableItem`.
    `Destroying.DisenchantDrops` gates on that matrix — keep new
    equip-slot/class checks on it, not on tuple positions.
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
- **In-game config → brain contract** (issues #15/#16, 2026-11-18;
  reworked per `WoWVault\Proposals\onboarding-ux-proposal.md`):
  onboarding is a multi-page wizard (`Onboarding.lua` `PAGES` —
  backend → api → import → app → options; CONNECT advances to api,
  SKIP also goes to api — the Blizzard feed is independent of the
  backend so solo players must still see it). Every config page
  stages a hex request in the SV (`backendReqs` `bm-`, `apiReqs`
  `api-` via `GM.StageApiReq`); the watcher's
  `process_backend_reqs`/`process_api_reqs` fold the newest into
  `feeds.json` (`api` block: client_id/secret/region/realms
  `{scope:0}`/poll 30m) and emit `backend.ack`/`api.ack` so the addon
  clears pending flags. `install.py` non-host path is register-only
  (no prompts — config is in-game); `--host` keeps the interactive
  server path + writes `backend-invite.txt` (durable URL+key share
  card beside the bat). **`goblin-watch.bat` self-registers**: on
  first run inside a WoW install it calls `install.py --register`
  (writes the per-user Startup bat only) and prints the undo path —
  one double-click is ever needed. `GM.EmitAge()` (secs since
  `GoblinMindDB.generated`) drives companion-app hints — >900s =
  silent. `GM.db.hideUnlearned` = spoiler-free crafting (RecipeRows
  skips unlearned rows); toggled on the OPTIONS page.
  **Emit surface for the wizard**: `GoblinMindDB.brain` = watcher
  absolute dir + bat path (the app page shows it in a selectable
  box — the addon can't resolve its own install dir);
  `backend.lastError`/`api.error` = last failed direction's err
  string (`_backend_health` records err on ok=False; `api_last`
  records poll ok/err in the watch loop) so a bad secret or dead
  host surfaces as "rejected"/"can't reach" instead of false
  "configured"; `backend.invite` = {url,key} emitted ONLY when
  `_local_server_secret` proves this machine hosts the server —
  the install secret must never ride the emit otherwise. BugReport
  `Collect()` must never include `GoblinMindDB.brain` (username in
  the path). `/goblin status` prints a queued-count line from
  `bugReports`+`backendReqs`+`apiReqs` lengths.
- **Sale-delta engine semantics** (2026-11-18, `delta_record`):
  disappeared lots are sale candidates ONLY after relist matching —
  per item, appeared lots in the new book cancel gone lots when
  they share a unit price (restack relist) or stack size (reprice
  relist); each new lot cancels at most one old. Cross-seller
  collisions suppress too (undercount > inflate). After matching,
  's'/'u' candidates priced >10x the item's MEDIAN listed unit (old
  snapshot, count-weighted) demote to 'i' — anchor walls cancelled
  and reposted under an identical fingerprint are invisible to
  matching and are the dominant fake-sale source (~30% of events
  on first live data). `book_t <= prev_t`
  snapshots are skipped (replay guard). Event shape is
  `[t, units, unit, gone, prev_item_lots, cls]` — e[4] is the item's
  TOTAL listed lots (not per-prefix) so `rsalep`'s denominator is
  honest; take `max(e[4])` across the window, never `sum`. cls:
  's' provable-time-left / 'i' inconclusive (excluded from stats) /
  'u' no-tl (counted). `delta_stats` also emits `veln` = event
  count — the confidence signal consumers need to judge vel.
  Regression coverage: `python brain\test_delta.py` (20 checks;
  stub api_state, synthetic lot snapshots).
- **Self-host backend auth** (2026-11-18): `_backend_token` falls
  back to `_local_server_secret` — a loopback `backend.url` with a
  `goblin_server.json` beside the script reuses its `install_secret`
  automatically. Self-hosters connect in-game with no key typing;
  remote servers still need the staged `key` field.
- **Full-scan stall fixes** (2026-11-18): the replicate poll gives
  up only on 20s of EMPTY buffer (40 polls) or a 4m absolute cap —
  never while the buffer still grows; `stable >= 8` (4s flat) marks
  stream end since this server trickles in bursts and 1s flat used
  to collect partial books. The Chunk watchdog (`Dog`) keeps
  rescheduling after a revive — an early `return` used to kill it,
  making a second stall permanent. Browse `b.tries` resets on every
  delivered page (three cumulative 4s pauses used to abort a
  healthy slow browse) and a hard stall now `FinishBrowse`s the
  partial book instead of discarding it.
- **Modified-click contract** (2026-11-18): any item row/icon
  handles modified clicks via `GM.ModifiedItemClick(id)` gated on
  `IsModifiedClick()` — NOT `IsShiftKeyDown()` (that silently drops
  ctrl+click dress-up and alt+click compare). Shared hooks:
  `W.ModifiedClick(row, idFn)` for rows with no own OnClick;
  dedicated icon-cover buttons (`detIconBtn`, `iconBtn`,
  `itP.iconBtn`, `m.hit`) carry their own gated OnClick since a
  child Button without one swallows the parent's handler.
  Intentional shift-only gates that stay: the qty-input box on
  vendoring buy buttons, `LinkHook`'s shift→search, `ItemInput`'s
  shift-capture, `Tooltip`'s shift-stack. Snipe/browse rows swallow
  ALL modified clicks unconditionally — a missed modifier must
  never fall through to a buy.
- **First-install/onboarding contract** (issues #5/#8, 2026-11-18):
  `Onboarding.MaybeShow` runs once per install off a persisted
  `GM.db.onboarded` flag — the in-game flow is the PRIMARY config
  path (install.bat only registers the watcher + Blizzard API;
  `install.bat --host` is the server-host path). Never gate the
  first-run prompt on `GoblinMindDB.backend` presence — the shipped
  Data.lua may not carry the block, which silently skipped
  onboarding for every fresh install.
- **`/goblin bug` staging cadence**: FILE REPORT stages via
  `GM.StageReport` only — no forced reload (`GM.After(1.5, ReloadUI)`
  silently never fired on this client). The staged report rides the
  ~90s SV autosave to the watcher; the chat message tells the user
  to /reload if they want it sent now.
- **Recipe-acquisition data pipeline** (beta phase 1, 2026-11-18):
  `brain/import_recipe_db.py` streams the cmangos classic-db dump
  (`brain/data/classicdb.sql.gz` — gitignored, download once from
  cmangos/classic-db `Full_DB/`) → `brain/recipe_sources.json`
  (tracked, shipped via BRAIN_FILES) → `load_recipe_sources()`
  folds it into both emit paths as `GoblinMindDB.recipeSources`.
  Join graph: npc_trainer/_template, npc_vendor/_template,
  creature+reference loot, quest rewards → item_template class=9
  teach-spells (trigger is ON_USE=0 on cmangos, NOT 6); template
  ids resolve through creature_template Trainer/VendorTemplateId.
  Gap: skill-line-gated recipes (bandages) come through DBC
  SkillLineAbility — no world-DB rows, so they emit no source.
- **Centered single-line labels anchor, don't justify**
  (issue #9 follow-up, 2026-11-18): `SetAllPoints()` +
  `SetJustifyH("CENTER")` on a fontstring does NOT survive —
  `FixupFonts` re-runs `SetFont` on every fontstring at login
  (Core.lua) and on each window's first show (PlanQueue), and the
  justify doesn't persist through it on this client. Use
  `SetPoint("CENTER")` + `SetWordWrap(false)` instead — the
  `W.Btn`/`W.SwitchBtn` pattern; anchor-based centering is
  justify-independent. Applies to any single-line centered text.
- **Profession recipe pump** (`Crafting.lua` `ProfPump`, issue #7):
  recipes only enumerate under an OPEN tradeskill line on this
  client, so a fresh profile captures nothing until each prof is
  opened. PLAYER_LOGIN → 6s delay → for each `GetProfessionInfo`
  skillLine missing from `GoblinMindCrafting.recipes` (by prof NAME
  via `C.Prof`), `C_TradeSkillUI.OpenTradeSkill(line)` paced 1s,
  then `CloseTradeSkill`. `C._pumping` suppresses the
  `OnTradeSkillOpen` UI takeover so the window doesn't flash per
  line. Self-heals partial captures (new profession learned later
  pumps just that line).
- Not yet registered on the Codebase Map (project started 2026-11-11,
  post-closure).
