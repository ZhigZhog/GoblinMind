# GoblinMind

A standalone auction-house intelligence addon for **World of Warcraft:
Forever** (interface `16001`). Price model, execution planner, crafting
planner, ledger, group/operation system, session takeovers — TSM-styled
dark UI, **no TSM required**.

**v0.5.3-alpha** — public alpha. Expect rough edges; bug reports file
themselves to the private tracker (see Bug reports below).

## Requirements

- World of Warcraft: Forever client (1.60.x, interface `16001`)
- Python 3.x on PATH — only for the companion **brain watcher**, which
  turns your SavedVariables into the emitted price DB and connects the
  optional crowdsource backend. The addon runs without it, but prices
  stay frozen at whatever shipped in the zip until the watcher emits.

## Install

1. Extract the zip into `Interface/AddOns/` — you should end up with
   `Interface/AddOns/GoblinMind/` and `Interface/AddOns/GoblinMind_Data/`.
2. Enable both addons at the character select screen.
3. **Run the installer** — double-click
   `Interface/AddOns/GoblinMind/brain/install.bat` once. It writes
   `feeds.json` (your realm scope, the shared backend's address, and
   the install key if the host uses one) and registers the brain
   watcher to auto-start at login. It also offers to set up a free
   Blizzard API client for the Blizzard feed (`skip` disables that
   feed — the local + backend feeds work regardless).
   - Prefer manual? Skip the installer and double-click
     `brain/goblin-watch.bat` while you play instead.
   - To **host** the shared backend on your machine, run
     `install.bat --host` (starts `goblin_server.py` now and opens
     TCP 8765 through Windows Firewall — one UAC prompt).
4. `/reload` (or relog). First login walks a two-page onboarding:
   **page 1 backend** (CONNECT / SKIP / LATER — optional; every feature
   works offline — re-open with `/goblin backend`), **page 2 import**
   (detects TSM and similar addons, lists what each import brings —
   groups/items/operations/custom price sources/saved searches — with
   a per-row IMPORT button; re-open with `/goblin import`).
5. Open the auction house once and hit **FULL SCAN** in the GoblinMind
   AH surface — that builds the first price book. The watcher folds it
   into the emitted DB on the next SavedVariables flush (`/reload`).

Until the first scan lands, price fields show `—` / `?` — that's
normal. The shipped `GoblinMind_Data` carries a starter book for
**CAMWOWUS1Realm5PvE-Alliance**; other scopes build their own book —
books are stored per realm+faction and never mix.

## How prices work

Your own AH scans build a local **book** (min-buyout, supply, your own
cheapest listing) in SavedVariables. The brain watcher merges every
character's book + ledger into `GoblinMindDB` (`GoblinMind_Data`), adds
long-term price history and velocity, and — if you opted in — folds in
the **crowdsourced backend book** (other installs' uploads, newest
wins) and the Blizzard API feed. In-game, every price read goes through
one merged entry per item: live book when fresh, backend/mesh data when
fresher, emitted DB as the floor. Provenance tags (`book`/`mesh`/emit)
drive the source labels on tooltips and stat lines.

## Using GoblinMind

### Targeting an item

Almost every surface works off a **target item**. Five ways to set one:

- `/goblin <link>` — shift-click a link into chat, or `/goblin 4238`,
  `/goblin i:4238`, `/goblin [Kingsblood]`
- `/goblin plan` — uses whatever item you're currently hovering
- **Drag-and-drop** an item onto the plan window's target slot
- **Shift-click** an item while the plan window is open (bags, mail,
  anywhere item clicks work) — keeps its normal Blizzard meaning
  (chat links, stack splits) and also becomes the plan's target
- Click a row anywhere in GoblinMind (Shopping hits, Ledger rows,
  Crafting list) — plain click targets that item

### Plan window (`/goblin`)

The command center. Top: target item + price/volume chart + market
stats (min buyout, market estimate, supply, velocity, provenance).
Below: the generated **plan** — buy cheap asks under your threshold,
post your stock at the target price, cancel undercut listings.
**EXECUTE performs exactly one action per click** — buy the cheapest
hit, post one stack, cancel one listing. Nothing is automated; that's
a ToS boundary held on purpose. The HOME tab on this window is the
dashboard: profitable crafts, restock candidates, undercut auctions,
and account balance at a glance.

### Market (`/goblin market` or `/goblin shop`)

Two pages. **SHOP** — per-item ask books: pick an item, see every
listed stack sorted by unit price, buy with one click per stack
(commodity multi-quantity where the AH supports it). **MY AUCTIONS** —
your active listings with undercut flags (sorted undercut-first), plus
a BAGS page that previews the post decision for every bag item using
the shared book — no scan needed. POST SCAN walks checked items.

### Sniper (`/goblin snipe`)

One-click AH-tail snapshots. Hits are ranked by %-of-market; click a
hit to open its ask book in Shopping, buy per click. Designed for
fast in-and-out camping without a continuous scan running.

### Crafting planner (`/goblin crafts`)

Replaces the professions frame. Left: professions + custom categories.
Middle: recipe list with profit, craftable count, and queue controls —
including **unlearned recipes within your level range** (grayed, with
acquisition info in the detail pane; they can never be queued).
Right: detail — material locations across bags/bank/mail/gbank/AH/alts,
full cost vs effective cost (mats you already own), profit vs buying
the mats. QUEUE builds a stock plan; the plan executes through the
tradeskill session with click-per-step crafts.

### Groups & operations (`/goblin groups`, `/goblin ops`)

TSM-style group trees. Groups contain items; **operations** (auctioning,
shopping, destroying, warehousing, crafting, mailing, vendoring) attach
to groups and inherit down the tree — everything ungrouped falls under
Base Group with the Default ops. Protected groups warn before
selling/posting their contents. TSM4 import/export strings supported.
`/goblin price <item> <expr>` sets a per-item custom price source —
TSM-compatible expressions like `min(dbmarket, 120% crafting)`.

### Ledger (`/goblin ledger`)

Every buy/sell/cancel GoblinMind performs is recorded per character and
per account. The overview shows balance trends, income/spend pie
charts, budgets, and the transaction history. `/goblin ledger N`
dumps the last N raw transactions to chat.

### Destroying (`/goblin destroy`)

Ranks bag items worth destroying instead of vendoring — disenchant EV
computed from the bracket drop tables times live mat prices, minus
market value. SCAN → PLAN pushes the picks into the plan queue.
Forever has no milling/prospecting, so herbs/ores only ever compare
disenchant vs vendor.

### Warehousing (`/goblin warehouse`)

Needs the bank frame open. Moves items between bags and bank to satisfy
each group's warehousing op (`keepQty`, `moveTo`) — emits one move
step per click into the plan queue.

### Task list (`/goblin tasks`)

Floating tracker — restock items, craft reminders, plan leftovers.
Survives reloads per character.

### Session takeovers

GoblinMind surfaces attach to the merchant, mail, bank, guild bank, AH,
and professions frames — each with a BLIZZARD UI button to flip back.
Vendor buy/sell with a blacklist (`/goblin vendor blacklist <item>`),
OPEN ALL mail with COD protection, permission-aware bank/gbank
transfers, posting/cancelling with unit/lot prices and undercut checks.

### Tooltips

- **Items** — market estimate, min-buyout, supply, velocity, vendor
  price, disenchant drops with per-drop prices and EV, provenance
  labels. Side-tip or embedded mode in settings.
- **Gathering nodes** — mining/herb nodes show the drop table with AH
  prices, gem probabilities, and expected node value.
- **Fishing pools/schools** — catch table and zone-scaled values.
- **Skinnable corpses** — level-banded leather yields and family
  specials.

## The backend (optional)

The crowdsource server pools uploads from every opted-in install into
a realm book — fresher prices, longer history, cross-character and
cross-install coverage. `/goblin backend` opens the onboarding dialog
(server URL, callsign, key if the host uses one); CONNECT stages a
request through SavedVariables and the watcher applies it — no restart.
`/goblin status` prints feed health, install count, and last
upload/pull. Self-host: `install.bat --host` on the server machine,
then hand the printed URL + key to your installs. Everything works
without the backend — your own scans and the mesh are sufficient.

## Command reference

`/goblinmind` and `/goblin` both work (`/gm` is shadowed on some setups).

| Command | Opens / does |
|---|---|
| `/goblin` | plan window (also the minimap button) |
| `/goblin <link\|i:id\|[name]\|id>` | target an item |
| `/goblin plan` | plan from the hovered item |
| `/goblin dash` / `home` / `budget` | dashboard home |
| `/goblin market` / `shop` | shopping + my auctions |
| `/goblin snipe` | sniper |
| `/goblin crafts` | crafting planner |
| `/goblin groups` | group tree |
| `/goblin ops` | operations |
| `/goblin ledger` | accounts, charts, history |
| `/goblin ledger N` | last N raw transactions in chat |
| `/goblin auctions` / `myauctions` | my auctions |
| `/goblin destroy` | destroying candidates |
| `/goblin warehouse` | warehousing scan (bank open) |
| `/goblin tasks` | task list float |
| `/goblin bank` / `gbank` / `mail` / `vendor` / `ah` | session surfaces |
| `/goblin vendor blacklist <item>` | toggle vendoring blacklist |
| `/goblin price <item> <expr>` | per-item custom price source |
| `/goblin inv <item>` | inventory breakdown for an item |
| `/goblin backend` | backend onboarding / reconfigure |
| `/goblin import` | addon-settings import screen (TSM etc.) |
| `/goblin status` | feed, backend, and mesh health |
| `/goblin perf` | 8s diagnostic sample (counters, frame walk) |
| `/goblin settings` / `options` | profiles, import/export, bug reports |
| `/goblin bug` | bug report window |
| `/goblin minimap` | toggle the minimap button |

## Bug reports

Settings → BUG REPORT (or `/goblin bug`) opens the report window —
diagnostics block + screenshot shortcut. FILE REPORT stages the report
in SavedVariables; the watcher files it to the private issue tracker
on the next flush and the addon clears it once filed.

## Rules of the road

- **Click-per-step only** — every protected Blizzard API call is bound
  to a hardware click. No automation, no afk loops.
- **Books are per realm+faction** — another scope's data never leaks
  into your prices.
- **Honest-nil** — no fabricated prices; fields stay `—`/`?` until real
  data exists.

## For hackers (private repo)

```
addons/GoblinMind/        the in-game addon (Lua)
addons/GoblinMind_Data/   generated price database addon (Data.lua is emitted)
brain/goblin_brain.py     SV watcher + book emitter + bug filer + backend client
brain/goblin_server.py    crowdsource backend (optional, self-hostable)
scripts/                  deploy helpers (sync-addons.bat, package-release.py)
WoWVault/                 design notes — architecture, Forever API surface,
                          TSM theme palette, code notes, API reference
AGENTS.md                 project conventions + client quirks
```

Watcher: `python brain\goblin_brain.py watch forever -v --feed book`
(feeds defined in `brain\feeds.json`; `watch self` inside an install).
See `AGENTS.md` for the client quirks list — no `SetBackdrop`, secret
strings under taint, non-retail price-field semantics, hard per-script
CPU budget (all render-path helpers are memoized — see
`GM.BucketCache`/`GM.BucketMemo`), and more.
