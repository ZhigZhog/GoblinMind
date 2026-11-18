#!/usr/bin/env python3
"""Import recipe-acquisition sources from a cmangos classic-db dump.

Streams the (optionally gzipped) mysqldump — no database server
needed — and emits recipe_sources.json keyed by recipe SPELL id
(the same id C_TradeSkillUI uses as recipeID):

    { "3275": [ {"kind":"trainer","name":"X","cost":1200},
                {"kind":"vendor","name":"Y","cost":3200},
                {"kind":"drop","name":"Z","chance":2.1},
                {"kind":"quest","name":"Q"} ], ... }

Join graph:

    npc_trainer(_template).spell          -> recipe spell, direct
    npc_vendor(_template).item            -> recipe item
    creature/reference_loot_template.item -> recipe item
    quest_template reward columns         -> recipe item
    item_template.spellid_N (trigger 6)   -> item teaches spell
    creature_template                   -> npc names + template ids

Usage: python import_recipe_db.py <dump.sql[.gz]> [out.json]
       (defaults: classicdb.sql.gz in this dir -> recipe_sources.json)
"""
import csv, gzip, io, json, re, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = sys.argv[1] if len(sys.argv) > 1 else str(HERE / "classicdb.sql.gz")
OUT = sys.argv[2] if len(sys.argv) > 2 else str(HERE / "recipe_sources.json")

# column orders lifted from the dump's CREATE TABLEs (cmangos classic)
COLS = {
    "item_template": ["entry", "class", "subclass", "name"]
        + [f"c{i}" for i in range(4, 70)]
        + ["spellid_1", "spelltrigger_1"],
    "npc_trainer": ["entry", "spell", "spellcost"],
    "npc_trainer_template": ["entry", "spell", "spellcost"],
    "npc_vendor": ["entry", "item"],
    "npc_vendor_template": ["entry", "item"],
    "creature_loot_template":
        ["entry", "item", "ChanceOrQuestChance", "groupid",
         "mincountOrRef"],
    "reference_loot_template":
        ["entry", "item", "ChanceOrQuestChance", "groupid",
         "mincountOrRef"],
    "quest_template": None,   # positional picks below
    "creature_template": None,
}
QUEST_COLS = {"entry": 0, "Title": 30,
              "RewChoice": [68, 69, 70, 71, 72, 73],
              "RewItem": [80, 81, 82, 83]}
CREATURE_COLS = {"Entry": 0, "Name": 1,
                 "TrainerTemplateId": 75, "VendorTemplateId": 76}
# item_template spell slots: (id_idx, trigger_idx) — trigger 6 = learn
SPELL_SLOTS = [(70, 71), (77, 78), (84, 85), (91, 92), (98, 99)]

TABLE_RE = re.compile(r"INSERT INTO `?(\w+)`?")
INT_RE = re.compile(r"^-?\d+$")


def open_src(p):
    return (gzip.open(p, "rt", encoding="utf-8", errors="replace")
            if str(p).endswith(".gz")
            else open(p, "rt", encoding="utf-8", errors="replace"))


def rows_of(stmt):
    """Yield each (...) tuple's field list from an INSERT statement."""
    body = stmt[stmt.find("VALUES") + 6:]
    # mysql VALUES use backslash escapes — csv module handles quoting
    # if we feed it the inside of each (...) group separately
    for m in re.finditer(r"\((.*?)\)\s*(?=,|;|\s*$)", body, re.S):
        rd = csv.reader(io.StringIO(m.group(1)), quotechar="'",
                        escapechar="\\", skipinitialspace=True)
        yield next(rd)


def num(v):
    return int(v) if v and INT_RE.match(v) else None


def main():
    teaches = {}          # item -> taught spell id
    item_name = {}        # item -> name
    npc_name = {}         # creature entry -> name
    tr_tmpl, vd_tmpl = {}, {}   # template id -> [npc names]
    spell_trainers = {}   # spell -> [(npc_or_tmpl_id, cost)]
    item_vendors = {}     # item -> [npc_or_tmpl_id]
    ref_loot = {}         # ref id -> [(creature entry unused)]
    item_drops = {}       # item -> [(creature entry, chance)]
    item_quests = {}      # item -> [quest title]

    cur_table, buf = None, ""
    n_ins = 0
    with open_src(SRC) as f:
        for line in f:
            if cur_table is None:
                m = TABLE_RE.match(line)
                if not m or m.group(1) not in COLS:
                    continue
                cur_table = m.group(1)
                buf = line
                if not line.rstrip().endswith(";"):
                    continue
            else:
                buf += line
                if not line.rstrip().endswith(";"):
                    continue
            stmt, cur_table, buf = buf, None, ""
            t = TABLE_RE.match(stmt).group(1)
            n_ins += 1
            if t == "item_template":
                for r in rows_of(stmt):
                    if len(r) < 100:
                        continue
                    e = num(r[0])
                    if e is None:
                        continue
                    item_name[e] = r[3]
                    # class 9 = Recipe: its spellid_N is the teach
                    # spell (trigger is ON_USE=0 on cmangos, not 6)
                    if r[1] == "9":
                        for si, ti in SPELL_SLOTS:
                            if (si < len(r) and r[si]
                                    and r[si] != "0"):
                                teaches[e] = num(r[si])
                                break
            elif t == "creature_template":
                for r in rows_of(stmt):
                    if len(r) <= CREATURE_COLS["VendorTemplateId"]:
                        continue
                    e = num(r[0])
                    if e is None:
                        continue
                    npc_name[e] = r[1]
                    tr = num(r[CREATURE_COLS["TrainerTemplateId"]])
                    vd = num(r[CREATURE_COLS["VendorTemplateId"]])
                    if tr:
                        tr_tmpl.setdefault(tr, []).append(r[1])
                    if vd:
                        vd_tmpl.setdefault(vd, []).append(r[1])
            elif t.startswith("npc_trainer"):
                for r in rows_of(stmt):
                    if len(r) < 3:
                        continue
                    e, sp = num(r[0]), num(r[1])
                    if e and sp:
                        spell_trainers.setdefault(
                            sp, []).append((e, num(r[2]) or 0))
            elif t.startswith("npc_vendor"):
                for r in rows_of(stmt):
                    if len(r) < 2:
                        continue
                    e, it = num(r[0]), num(r[1])
                    if e and it:
                        item_vendors.setdefault(it, []).append(e)
            elif t == "reference_loot_template":
                for r in rows_of(stmt):
                    if len(r) < 5:
                        continue
                    e, it = num(r[0]), num(r[1])
                    if e and it:
                        ref_loot.setdefault(e, []).append(
                            (it, num(r[2])))
            elif t == "creature_loot_template":
                for r in rows_of(stmt):
                    if len(r) < 5:
                        continue
                    e, it = num(r[0]), num(r[1])
                    mref = num(r[4])
                    if e and mref and mref < 0:
                        # reference row — map ref's items onto this npc
                        for rit, ch in ref_loot.get(-mref, []):
                            item_drops.setdefault(rit, []).append(
                                (e, ch))
                    elif e and it:
                        item_drops.setdefault(it, []).append(
                            (e, num(r[2])))
            elif t == "quest_template":
                ti = QUEST_COLS["Title"]
                for r in rows_of(stmt):
                    if len(r) <= max(QUEST_COLS["RewItem"]):
                        continue
                    title = r[ti]
                    if not title:
                        continue
                    for idx in (QUEST_COLS["RewChoice"]
                                + QUEST_COLS["RewItem"]):
                        it = num(r[idx])
                        if it:
                            item_quests.setdefault(it, []).append(
                                title)

    # resolve item-sourced joins through the teaches map
    out = {}

    def add(spell, rec):
        if spell:
            lst = out.setdefault(spell, [])
            if rec not in lst:
                lst.append(rec)

    for sp, lst in spell_trainers.items():
        for e, cost in lst:
            if e < 0:
                for nm in tr_tmpl.get(-e, []):
                    add(sp, {"kind": "trainer", "name": nm})
            else:
                rec = {"kind": "trainer",
                       "name": npc_name.get(e, f"npc {e}")}
                if cost:
                    rec["cost"] = cost
                add(sp, rec)
    for it, ids in item_vendors.items():
        sp = teaches.get(it)
        if not sp:
            continue
        for e in ids:
            names = (vd_tmpl.get(-e) if e < 0
                     else [npc_name.get(e, f"npc {e}")])
            for nm in names or []:
                add(sp, {"kind": "vendor", "name": nm})
    for it, lst in item_drops.items():
        sp = teaches.get(it)
        if not sp:
            continue
        seen = set()
        for e, ch in lst:
            nm = npc_name.get(e)
            if not nm or nm in seen:
                continue
            seen.add(nm)
            rec = {"kind": "drop", "name": nm}
            if ch and 0 < abs(ch) < 100:
                rec["chance"] = round(abs(ch), 1)
            add(sp, rec)
    for it, titles in item_quests.items():
        sp = teaches.get(it)
        if not sp:
            continue
        for tname in dict.fromkeys(titles):
            add(sp, {"kind": "quest", "name": tname})

    # bound per-spell source lists — world-drop recipes otherwise list
    # hundreds of 0.02% mobs; the top few by chance are the useful
    # ones, and the emit pays for every row we keep
    CAP = {"drop": 8, "trainer": 8, "vendor": 8, "quest": 6}
    for sp, lst in out.items():
        lst.sort(key=lambda r: (
            0 if r["kind"] == "trainer" else 1 if r["kind"] == "vendor"
            else 2 if r["kind"] == "quest" else 3,
            -r.get("chance", 0)))
        per = {}
        out[sp] = [r for r in lst
                   if per.get(r["kind"], 0) < CAP[r["kind"]]
                   and not per.__setitem__(r["kind"],
                                           per.get(r["kind"], 0) + 1)]

    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(out, f, separators=(",", ":"), sort_keys=True)

    kinds = {}
    for lst in out.values():
        for r in lst:
            kinds[r["kind"]] = kinds.get(r["kind"], 0) + 1
    print(f"{n_ins} INSERTs scanned · {len(item_name)} items · "
          f"{len(teaches)} teach-spells · {len(npc_name)} npcs")
    print(f"-> {len(out)} recipe spells sourced "
          f"({', '.join(f'{k}:{v}' for k, v in sorted(kinds.items()))})")
    print(f"wrote {OUT} "
          f"({Path(OUT).stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
