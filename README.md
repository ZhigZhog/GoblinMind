# GoblinMind

A standalone auction-house intelligence addon for **World of Warcraft:
Forever** (interface `16001`). TSM-styled dark UI, in-house price feed,
click-per-step execution — no TSM required.

**v0.1.0-alpha** — first public alpha. Expect rough edges; bug reports
file themselves to the private tracker (see below).

## Install

1. Extract the zip into `Interface/AddOns/` — you should end up with
   `Interface/AddOns/GoblinMind/` and `Interface/AddOns/GoblinMind_Data/`.
2. Enable both addons at the character select screen.
3. **Run the brain watcher** — double-click
   `Interface/AddOns/GoblinMind/brain/goblin-watch.bat` and leave the
   window open while you play (needs Python 3.x on PATH). It keeps your
   price data fresh and files bug reports. Without it the addon still
   runs, but prices stay frozen at whatever shipped in the zip.
4. `/reload` (or relog), then open the auction house once — GoblinMind
   builds its own price book from the live AH (FULL SCAN button in the
   AH window, or it collects passively in the background).
5. Prices populate as the book fills. Until the first scan completes,
   price fields show `—` / `?` — that's normal.

The shipped `GoblinMind_Data` includes a starter price book for
**CAMWOWUS1Realm5PvE-Alliance**. Players on other realms/factions will
build their own book on first use — books are stored per
realm+faction and never mix.

## What it does

- **Plan window** (`/goblin`) — target an item by `/goblin [link]`,
  drag-and-drop, or Alt-click. Price/volume chart, market stats, and a
  step-by-step plan: buy cheap asks, post your stock at the target
  price. EXECUTE performs one action per click — nothing is automated.
- **Price tooltips** — market estimate, sell velocity, and supply on
  every item tooltip.
- **Sniper** (`/goblin snipe`) — one-click snapshots of the AH tail,
  hits sorted by %-of-market, scan-then-buy flow.
- **Shopping** (`/goblin shop`) — per-item ask books, grouped hits,
  commodity multi-quantity buys, scan from the sniper.
- **Crafting planner** — replaces the professions frame: searchable
  recipes, material locations across bags/bank/mail/gbank/AH/alts,
  craftable counts, profit vs buying the mats, queues and stock plans.
- **Groups & operations** (`/goblin groups`, `/goblin ops`) —
  TSM-style group trees with inheritable operations, protected groups
  (warns before selling/posting their contents), TSM import/export.
- **Ledger** (`/goblin ledger`) — buys/sells/cancels history, account
  budgets with balance trends and income/spend pie charts.
- **Session takeovers** — merchant, mail, bank, guild bank, AH, and
  professions frames get GoblinMind surfaces (with a BLIZZARD UI button
  to go back). Vendor buy/sell, OPEN ALL mail with COD protection,
  permission-aware bank/gbank transfers, posting/cancelling with
  unit/lot prices and undercut checks.
- **Gathering tooltips** — mining/herb nodes show drop tables, per-drop
  AH prices, gem probabilities, and expected node value. Skinnable
  corpses show level-banded leather yields and family specials.
- **Task list** (`/goblin tasks`) — floating to-do tracker for restock
  and craft reminders.

## Commands

| Command | Opens |
|---|---|
| `/goblin` | plan window (also the minimap button) |
| `/goblin shop` / `market` | shopping + my auctions |
| `/goblin snipe` | sniper |
| `/goblin crafts` | crafting planner |
| `/goblin groups` / `ops` | group tree / operations |
| `/goblin ledger` | accounts, charts, history |
| `/goblin tasks` | task list float |
| `/goblin bank` / `gbank` / `mail` / `vendor` / `ah` | session surfaces |
| `/goblin settings` | profiles, import/export, bug reports |
| `/goblin minimap` | toggle the minimap button |

## Rules of the road

- **Click-per-step only** — every protected Blizzard API call is bound
  to a hardware click. No automation, no afk loops. That's a ToS
  boundary we hold on purpose.
- **Books are per realm+faction** — data from another scope never leaks
  into your prices.
- **Bug reports** — Settings has a report button; it stages a report in
  SavedVariables (diagnostics + recent Lua errors) and the external
  brain files it to the private issue tracker automatically.

## For hackers (private repo)

```
addons/GoblinMind/        the in-game addon (Lua)
addons/GoblinMind_Data/   generated price database addon (Data.lua is emitted)
brain/goblin_brain.py     SV watcher + book emitter + bug-report filer
scripts/                  deploy helpers (sync-addons.bat copies into AddOns)
WoWVault/                 design notes — architecture, Forever API surface,
                          TSM theme palette, code notes
AGENTS.md                 project conventions + client quirks
```

Watcher: `python brain\goblin_brain.py watch forever -v --feed book`
(feeds defined in `brain\feeds.json`). See `AGENTS.md` for the client
quirks list — no `SetBackdrop`, secret strings under taint, non-retail
price-field semantics, and more.
