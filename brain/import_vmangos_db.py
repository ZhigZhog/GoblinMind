#!/usr/bin/env python3
"""Merge vmangos world-DB recipe sources into recipe_sources.json.

Complements import_recipe_db.py (cmangos mysqldump): vmangos ships a
SQLite world db whose `skill_line_ability` table carries the
skill-line-gated trainer spells that world-db trainer tables never
list — vanilla trainers offer them dynamically from the client's
SkillLineAbility (e.g. Goblin Rocket Boots 8895, absent from every
npc_trainer). Emits the same record shape:

    {spell: [ {"kind":"trainer","name":"X","cost":?,"req":?},
              {"kind":"auto","name":"…"},
              {"kind":"vendor","name":"X","cost":?},
              {"kind":"drop","name":"X","chance":?},
              {"kind":"quest","name":"Q"} ] }

Merge rules vs the existing JSON:
  * specific (named) source rows from either db win as-is, deduped
    by (kind, name)
  * the generic "any <Prof> trainer" row is only added when a spell
    has sources but no trainer row (skill-gated recipes ARE offered
    by every profession trainer — naming one would be wrong)
  * "auto" rows mark learn_on_get_skill spells (Linen Bandage etc.)

Usage: python import_vmangos_db.py [mangos.sqlite] [recipe_sources.json]
       defaults: brain/data/mangos.sqlite -> brain/recipe_sources.json
"""
import json
import sqlite3
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "data" / "mangos.sqlite"
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else HERE / "recipe_sources.json"

BUILD = 5875  # vanilla 1.12 — matches Forever's recipe/skill-line ids
# skill ids with crafting professions — logs=0 rows for weapon/class
# skills are class spells, not recipes, and would only add noise
SKILL_NAMES = {
    129: 'First Aid', 164: 'Blacksmithing', 165: 'Leatherworking',
    171: 'Alchemy', 182: 'Herbalism', 185: 'Cooking', 197: 'Tailoring',
    202: 'Engineering', 333: 'Enchanting', 356: 'Fishing',
    393: 'Skinning',
}
# cap named-source fan-out per spell — a schematic sold by 40 vendors
# reads the same as 3 in the pane
MAX_NAMED = 4


def learn_spells(c):
    """item entry -> spell it teaches (spelltrigger 6 = learn)."""
    out = {}
    for n in range(1, 6):
        for item, spell in c.execute(
                f"select entry, spellid_{n} from item_template "
                f"where spelltrigger_{n}=6 and spellid_{n}>0"):
            out[item] = spell
    return out


def npc_names(c):
    return {e: n for e, n in c.execute(
        "select entry, name from creature_template")}


def trainer_rows(c, names, tmpl_ids):
    """npc_trainer + npc_trainer_template -> spell -> source rows."""
    rows = {}
    for ent, spell, cost, rq, rv in c.execute(
            "select entry, spell, spellcost, reqskill, reqskillvalue "
            "from npc_trainer where build_min<=? and build_max>=? "
            "or build_min is null", (BUILD, BUILD)):
        name = names.get(ent)
        if not name:
            continue
        rec = {"kind": "trainer", "name": name}
        if cost:
            rec["cost"] = cost
        if rv:
            rec["req"] = rv
        rows.setdefault(spell, []).append(rec)
    # template table: entry is a trainer-template id resolved through
    # creature_template.trainer_id
    tmpl_npcs = {}
    for ent, tid in c.execute(
            "select entry, trainer_id from creature_template "
            "where trainer_id>0"):
        if names.get(ent):
            tmpl_npcs.setdefault(tid, []).append(ent)
    for tid, spell, cost, rq, rv in c.execute(
            "select entry, spell, spellcost, reqskill, reqskillvalue "
            "from npc_trainer_template where build_min<=? and "
            "build_max>=? or build_min is null", (BUILD, BUILD)):
        for ent in (tmpl_npcs.get(tid) or [])[:MAX_NAMED]:
            rec = {"kind": "trainer", "name": names[ent]}
            if cost:
                rec["cost"] = cost
            if rv:
                rec["req"] = rv
            rows.setdefault(spell, []).append(rec)
    return rows


def vendor_rows(c, names, taught):
    """npc_vendor sells RECIPE ITEMS -> map back to taught spells."""
    rows = {}

    def add(ent, item):
        spell = taught.get(item)
        name = names.get(ent)
        if not (spell and name):
            return
        rec = {"kind": "vendor", "name": name}
        cost = prices.get(item)
        if cost:
            rec["cost"] = cost
        rows.setdefault(spell, []).append(rec)

    prices = {e: p for e, p in c.execute(
        "select entry, buy_price from item_template where buy_price>0")}
    for ent, item in c.execute("select entry, item from npc_vendor"):
        add(ent, item)
    vend_npcs = {}
    for ent, vid in c.execute(
            "select entry, vendor_id from creature_template "
            "where vendor_id>0"):
        if names.get(ent):
            vend_npcs.setdefault(vid, []).append(ent)
    for vid, item in c.execute(
            "select entry, item from npc_vendor_template"):
        for ent in (vend_npcs.get(vid) or [])[:MAX_NAMED]:
            add(ent, item)
    return rows


def drop_rows(c, names, taught):
    """creature loot (+ reference templates) on recipe items."""
    # entry -> creature names via creature_template.loot_id
    loot_npcs = {}
    for ent, lid in c.execute(
            "select entry, loot_id from creature_template "
            "where loot_id>0"):
        if names.get(ent):
            loot_npcs.setdefault(lid, []).append(ent)

    def scan(table):
        for le, item, ch, _grp, ref in c.execute(
                f"select entry, item, ChanceOrQuestChance, groupid, "
                f"mincountOrRef from {table}"):
            if ref and ref < 0:
                continue            # reference rows resolved below
            if ch is None or ch <= 0:
                continue            # quest-only / guaranteed-flag rows
            spell = taught.get(item)
            if not spell:
                continue
            yield spell, le, round(float(ch), 2)

    rows = {}
    for spell, le, ch in scan("creature_loot_template"):
        for ent in (loot_npcs.get(le) or [])[:MAX_NAMED]:
            rows.setdefault(spell, []).append(
                {"kind": "drop", "name": names[ent], "chance": ch})
    # reference templates: creature loot rows with mincountOrRef<0
    # name a reference_loot_template entry in their `item` column
    ref_npcs = {}
    for le, item, _ch, _grp, ref in c.execute(
            "select entry, item, ChanceOrQuestChance, groupid, "
            "mincountOrRef from creature_loot_template"):
        if ref and ref < 0:
            for ent in (loot_npcs.get(le) or []):
                ref_npcs.setdefault(item, set()).add(ent)
    for spell, le, ch in scan("reference_loot_template"):
        for ent in list(ref_npcs.get(le) or ())[:MAX_NAMED]:
            rows.setdefault(spell, []).append(
                {"kind": "drop", "name": names[ent], "chance": ch})
    return rows


def quest_rows(c, taught):
    """quest_template reward columns on recipe items."""
    cols = [f"RewChoiceItemId{n}" for n in range(1, 7)] \
        + [f"RewItemId{n}" for n in range(1, 5)]
    sel = ", ".join(cols)
    rows = {}
    for r in c.execute(f"select entry, Title, {sel} from quest_template"):
        title = r[1]
        for item in r[2:]:
            spell = taught.get(item)
            if spell and title:
                rows.setdefault(spell, []).append(
                    {"kind": "quest", "name": title})
    return rows


def skill_rows(c):
    """skill_line_ability: the trainer-table hole. learn_on_get_skill
    0 = any profession trainer offers it (skill-gated); 1 = granted
    automatically when the skill ranks up. build-filtered."""
    rows = {}
    auto = {}
    q = ("select skill_id, spell_id from skill_line_ability "
         "where learn_on_get_skill=? and build=?")
    for skill, spell in c.execute(q, (0, BUILD)):
        prof = SKILL_NAMES.get(skill)
        if prof:
            rows.setdefault(spell, []).append(
                {"kind": "trainer", "name": f"any {prof} trainer",
                 "generic": True})
    for skill, spell in c.execute(q, (1, BUILD)):
        prof = SKILL_NAMES.get(skill)
        if prof:
            auto.setdefault(spell, []).append(
                {"kind": "auto",
                 "name": f"learned automatically ({prof} skillup)"})
    return rows, auto


def merge(into, *row_maps, generic_ok=True):
    """union source lists per spell, dedupe by (kind, name); generic
    'any <Prof> trainer' only when no specific trainer row exists."""
    for m in row_maps:
        for spell, recs in m.items():
            dst = into.setdefault(spell, [])
            have = {(r["kind"], r["name"]) for r in dst}
            has_named_trainer = any(
                r["kind"] == "trainer" and not r.get("generic")
                for r in dst)
            for r in recs:
                if r.get("generic") and has_named_trainer:
                    continue
                if (r["kind"], r["name"]) in have:
                    continue
                have.add((r["kind"], r["name"]))
                r = dict(r)
                r.pop("generic", None)
                dst.append(r)


def main():
    if not SRC.exists():
        sys.exit(f"missing {SRC} — download the vmangos db-sqlite "
                 "release into brain/data/")
    c = sqlite3.connect(str(SRC))
    names = npc_names(c)
    taught = learn_spells(c)
    out = {}
    if OUT.exists():
        out = {int(k): v for k, v in
               json.loads(OUT.read_text(encoding="utf8")).items()}
    # named sources first — the generic "any <Prof> trainer" row must
    # merge last so it can defer to real trainer names
    merge(out, trainer_rows(c, names, None))
    merge(out, vendor_rows(c, names, taught))
    merge(out, drop_rows(c, names, taught))
    merge(out, quest_rows(c, taught))
    sk, auto = skill_rows(c)
    merge(out, sk)
    merge(out, auto)
    OUT.write_text(json.dumps(out, separators=(",", ":")),
                   encoding="utf8")
    print(f"{len(out)} spells -> {OUT}")
    print("8895:", out.get(8895))


if __name__ == "__main__":
    main()
