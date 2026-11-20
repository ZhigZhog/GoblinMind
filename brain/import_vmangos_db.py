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

NPC rows also carry "pos":[map,x,y] (first spawn), "zone" from the
nearest taxi_nodes entry's 'Town, Zone' name (else the map name) and
"town" from a close points_of_interest landmark (<800yd) or the taxi
town (<3000yd); quest rows carry "zone" from ZoneOrSort. Duplicate
(kind,name) rows are backfilled with these keys on re-run.

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
# reads the same as 3 in the pane; world drops come off hundreds of
# loot templates, so per-spell totals also need a hard cap
MAX_NAMED = 4
MAX_DROPS = 6


POI_TOWN_SQ = 800 ** 2      # POIs name subzones — only count when close
TAXI_TOWN_SQ = 3000 ** 2    # taxi-node town label cutoff


def spawn_map(c):
    """creature-template entry -> first (map,x,y) spawn. creature rows
    list up to five possible ids — all spawn at the same point."""
    sp = {}
    for r in c.execute(
            "select id,id2,id3,id4,id5,map,position_x,position_y "
            "from creature"):
        m, x, y = r[5], r[6], r[7]
        for e in r[:5]:
            if e and e not in sp:
                sp[e] = (m, round(x), round(y))
    return sp


def poi_points(c, spawns):
    """(map,x,y,name) for each point_of_interest. The table has no
    map column; each POI is assigned the map with the most spawns in
    its neighbourhood — POIs sit in populated areas so the correct
    map's spawn cloud is always nearer than a wrong-map coincidence."""
    by_map = {}
    for m, x, y in spawns.values():
        by_map.setdefault(m, []).append((x, y))
    out = []
    for x, y, name in c.execute(
            "select x, y, icon_name from points_of_interest"):
        if not name:
            continue
        best, bd = None, None
        for m, pts in by_map.items():
            d = min((x - px) ** 2 + (y - py) ** 2 for px, py in pts[::7])
            if bd is None or d < bd:
                best, bd = m, d
        if best is not None:
            out.append((best, x, y, name))
    return out


def taxi_nodes(c):
    """(map,x,y,town,zone) for each flight node — names like
    'Sentinel Hill, Westfall' carry the zone after the comma. 105
    nodes blanket the world, so the nearest one's zone part is a
    solid zone assignment (wrong only near borders)."""
    out = []
    for m, x, y, name in c.execute(
            "select map_id, x, y, name from taxi_nodes"):
        if not name:
            continue
        town, _, zone = name.partition(", ")
        out.append((m, x, y, town or None, zone or None))
    return out


def map_names(c):
    return {e: n for e, n in c.execute(
        "select entry, map_name from map_template")}


def area_names(c):
    return {e: n for e, n in c.execute(
        "select entry, name from area_template")}


def _zone_at(m, x, y, pois, taxis, mapnames, rec):
    """zone/town/pos math shared by locate() and the name-index
    backfill. zone = zone part of the nearest same-map taxi node
    ('Town, Zone' names), else the map name. town = close POI
    (<800yd, subzone names) else the taxi town when <3000yd."""
    rec["pos"] = [m, x, y]
    tn, td = None, None
    for tm, tx, ty, town, zone in taxis:
        if tm != m:
            continue
        d = (x - tx) ** 2 + (y - ty) ** 2
        if td is None or d < td:
            tn, td = (town, zone), d
    pn, pd = None, POI_TOWN_SQ
    for pm, px, py, name in pois:
        if pm != m:
            continue
        d = (x - px) ** 2 + (y - py) ** 2
        if d < pd:
            pn, pd = name, d
    if tn:
        rec["zone"] = tn[1] or mapnames.get(m)
        if tn[0] and td <= TAXI_TOWN_SQ:
            rec["town"] = tn[0]
    else:
        rec["zone"] = mapnames.get(m)
    if pn:                      # close POIs outrank the town label
        rec["town"] = pn


def locate(rec, ent, spawns, pois, taxis, mapnames):
    """attach pos/zone/town to a source row from the NPC's first
    spawn."""
    sp = spawns.get(ent)
    if not sp:
        return
    _zone_at(sp[0], sp[1], sp[2], pois, taxis, mapnames, rec)


def npc_geo(names, spawns, pois, taxis, mapnames):
    """npc name -> {zone,town,pos} from any spawned entry of that
    name. Trainer/vendor template lists are capped before they reach
    merge and cmangos rows carry no locations, so source rows whose
    NPC never made a vmangos row get backfilled by name here."""
    g = {}
    for ent, (m, x, y) in spawns.items():
        n = names.get(ent)
        if not n or n in g:
            continue
        rec = {}
        _zone_at(m, x, y, pois, taxis, mapnames, rec)
        g[n] = {k: rec[k] for k in ("zone", "town", "pos") if k in rec}
    return g


def learn_spells(c):
    """item entry -> craft spell it teaches. vmangos recipe items
    (class=9) point spellid_N at a LEARN spell; spell_template rows
    with effect=36 carry the craft spell in effectTriggerSpell_N."""
    trig = {}
    for n in (1, 2, 3):
        for sid, tgt in c.execute(
                f"select entry, effectTriggerSpell{n} from "
                f"spell_template where effect{n}=36 and "
                f"effectTriggerSpell{n}>0"):
            trig[sid] = tgt
    out = {}
    for n in range(1, 6):
        for item, spell in c.execute(
                f"select entry, spellid_{n} from item_template "
                f"where class=9 and spellid_{n}>0"):
            out[item] = trig.get(spell, spell)
    return out


def npc_names(c):
    return {e: n for e, n in c.execute(
        "select entry, name from creature_template")}


def trainer_rows(c, names, geo):
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
        locate(rec, ent, *geo)
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
            locate(rec, ent, *geo)
            rows.setdefault(spell, []).append(rec)
    return rows


def vendor_rows(c, names, taught, geo):
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
        locate(rec, ent, *geo)
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


def drop_rows(c, names, taught, geo):
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
            rec = {"kind": "drop", "name": names[ent], "chance": ch}
            locate(rec, ent, *geo)
            rows.setdefault(spell, []).append(rec)
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
            rec = {"kind": "drop", "name": names[ent], "chance": ch}
            locate(rec, ent, *geo)
            rows.setdefault(spell, []).append(rec)
    # world drops fan out across hundreds of mobs — keep the best
    # chance per NPC name, then the top MAX_DROPS per spell
    for spell, recs in rows.items():
        best = {}
        for r in recs:
            cur = best.get(r["name"])
            if cur is None or r["chance"] > cur["chance"]:
                best[r["name"]] = r
        rows[spell] = sorted(best.values(), key=lambda r: -r["chance"])[
            :MAX_DROPS]
    return rows


def quest_rows(c, taught, areas):
    """quest_template reward columns on recipe items. ZoneOrSort>0
    names the quest's zone — the only table in the db that maps a
    source directly to an area name."""
    cols = [f"RewChoiceItemId{n}" for n in range(1, 7)] \
        + [f"RewItemId{n}" for n in range(1, 5)]
    sel = ", ".join(cols)
    rows = {}
    for r in c.execute(
            f"select entry, Title, ZoneOrSort, {sel} "
            f"from quest_template"):
        title, zos = r[1], r[2]
        for item in r[3:]:
            spell = taught.get(item)
            if spell and title:
                rec = {"kind": "quest", "name": title}
                z = areas.get(zos) if zos > 0 else None
                if z:
                    rec["zone"] = z
                rows.setdefault(spell, []).append(rec)
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
            have = {(r["kind"], r["name"]): r for r in dst}
            has_named_trainer = any(
                r["kind"] == "trainer" and not r.get("generic")
                for r in dst)
            for r in recs:
                if r.get("generic") and has_named_trainer:
                    continue
                dup = have.get((r["kind"], r["name"]))
                if dup is not None:
                    # backfill keys the older import didn't emit
                    for k in ("zone", "town", "pos", "req", "cost",
                              "chance"):
                        if k in r and k not in dup:
                            dup[k] = r[k]
                    continue
                r = dict(r)
                r.pop("generic", None)
                dst.append(r)
                have[(r["kind"], r["name"])] = r


def main():
    if not SRC.exists():
        sys.exit(f"missing {SRC} — download the vmangos db-sqlite "
                 "release into brain/data/")
    c = sqlite3.connect(str(SRC))
    names = npc_names(c)
    taught = learn_spells(c)
    spawns = spawn_map(c)
    geo = (spawns, poi_points(c, spawns), taxi_nodes(c), map_names(c))
    areas = area_names(c)
    out = {}
    if OUT.exists():
        out = {int(k): v for k, v in
               json.loads(OUT.read_text(encoding="utf8")).items()}
    # named sources first — the generic "any <Prof> trainer" row must
    # merge last so it can defer to real trainer names
    merge(out, trainer_rows(c, names, geo))
    merge(out, vendor_rows(c, names, taught, geo))
    merge(out, drop_rows(c, names, taught, geo))
    merge(out, quest_rows(c, taught, areas))
    sk, auto = skill_rows(c)
    merge(out, sk)
    merge(out, auto)
    # name-index backfill: cmangos rows and template-capped NPCs (e.g.
    # Kartosh, one of many warlock trainers on template 14) get zones
    # from any spawned creature entry sharing their name
    geo_idx = npc_geo(names, spawns, geo[1], geo[2], geo[3])
    for recs in out.values():
        for r in recs:
            n = r.get("name")
            if n and "zone" not in r and n in geo_idx:
                r.update(geo_idx[n])
    # enforce the per-spell drop cap on the merged result too — older
    # imports may already carry a flood of low-value drop rows; keep
    # the best chance per NPC name, then the top MAX_DROPS
    for spell, recs in out.items():
        drops = [r for r in recs if r.get("kind") == "drop"]
        if len(drops) <= MAX_DROPS:
            continue
        best = {}
        for r in drops:
            cur = best.get(r["name"])
            if cur is None or r.get("chance", 0) > cur.get("chance", 0):
                best[r["name"]] = r
        keep = {id(r) for r in sorted(
            best.values(), key=lambda r: -r.get("chance", 0))[:MAX_DROPS]}
        out[spell] = [r for r in recs
                      if r.get("kind") != "drop" or id(r) in keep]
    OUT.write_text(json.dumps(out, separators=(",", ":")),
                   encoding="utf8")
    print(f"{len(out)} spells -> {OUT}")
    print("8895:", out.get(8895))


if __name__ == "__main__":
    main()
