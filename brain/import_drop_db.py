#!/usr/bin/env python3
"""Import static drop tables from the vmangos world db into
drop_sources.json — keyed by ITEM id (same orientation as
recipe_sources.json): "where does this item come from?"

    { "2318": [ {"src":"c3240","name":"Ravasaur","chance":38.5,"via":"kill"},
                {"src":"c3241","name":"Ravasaur Runner","chance":36.2,"via":"skin"},
                {"src":"i4632","name":"Ornate Bronze Lockbox","chance":1.8,"via":"cont"},
                {"src":"d12","name":"Disenchant ilvl 21-30","chance":20.0,"via":"de","qty":[1,2]},
                {"src":"f368","name":"Wetlands","chance":4.1,"via":"fish"},
                {"src":"o1683","name":"Sunken Chest","chance":0.9,"via":"loot"} ], ... }

Source keys mirror Drops.lua's live srcKey scheme — a creature the
live pipeline later observes matures the same bucket:

    c<entry>  creature_template entry (kill / pickpocket / skinning
              loot — `via` distinguishes; same key space)
    o<entry>  gameobject_template entry (type-3 chests; data1 loot id)
    i<entry>  container item (clams, lockboxes — item_loot_template)
    d<grp>    disenchant bracket — label derived from the fodder
              items sharing the disenchant_id (synthetic; live
              capture never produces one)
    f<zone>   fishing_loot_template zone id -> area_template name

Filters: end-of-vanilla content window (patch_min <= 10 <= patch_max),
unconditioned rows only (condition_id != 0 are aura/quest gates), and
POSITIVE ChanceOrQuestChance — negative means quest-bearer-only drops
and would lie on the tooltip. Reference rows (mincountOrRef < 0)
resolve recursively through reference_loot_template with chances
multiplied — the table-row chance is an approximation for grouped
entries (groupid>0 picks are weighted/mutually-exclusive inside the
engine; the flat chance stays close enough to rank sources, which is
all the tooltip needs).

Per source the effective rate merges duplicate occurrences as
independent rolls: rate = 1 - prod(1 - c_i). Over-counts
mutually-exclusive group members slightly — documented approximation.

Usage: python import_drop_db.py [mangos.sqlite] [drop_sources.json]
       defaults: brain/data/mangos.sqlite -> brain/drop_sources.json
"""
import json
import sqlite3
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "data" / "mangos.sqlite"
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else HERE / "drop_sources.json"

# content live at the final vanilla patch — drops removed mid-
# progression (patch_max < 10) don't exist on a 1.12-era server
PATCH = "patch_min <= 10 and patch_max >= 10"
KEEP = 8            # sources stored per item (tooltip shows 3)
FLOOR = 0.2         # tail cut below this % when >KEEP candidates
ROUND = 1           # chance decimals in the JSON
MAX_DEPTH = 4       # reference recursion guard


def rows(cur, table, tid=None):
    """(item, chance, minc, maxc) for one template entry (or all when
    tid is None — used for reference_loot_template preload)."""
    q = ("select item, ChanceOrQuestChance, mincountOrRef, maxcount "
         f"from {table} where {PATCH} and condition_id = 0 "
         "and ChanceOrQuestChance > 0")
    if tid is not None:
        q += f" and entry = {int(tid)}"
    return cur.execute(q)


def resolve(item_map, refs, mult=1.0, depth=0, seen=frozenset()):
    """{item: [(chance, lo, hi)]} -> expanded copy with reference rows
    resolved recursively (outer chance multiplies inner)."""
    out = {}
    for item, occ in item_map.items():
        for ch, lo, hi in occ:
            ref = -lo if lo < 0 else (-item if item < 0 else 0)
            if ref:
                if depth >= MAX_DEPTH or ref in seen or ref not in refs:
                    continue
                for it, oc in resolve(refs[ref], refs, mult * ch,
                                      depth + 1, seen | {ref}).items():
                    out.setdefault(it, []).extend(oc)
            elif item > 0:
                out.setdefault(item, []).append((mult * ch, lo, hi))
    return out


def template(cur, refs, table, tid):
    """resolved {item: [(chance, lo, hi)]} for one template entry."""
    occ = {}
    for item, ch, lo, hi in rows(cur, table, tid):
        occ.setdefault(item, []).append((ch / 100.0, lo, hi))
    return resolve(occ, refs)


def merged_rate(occ):
    """independent-roll merge of an item's occurrences in one table."""
    keep = 1.0
    for p, _l, _h in occ:
        keep *= 1.0 - min(1.0, p)
    return 1.0 - keep


def merged_qty(occ):
    lo = min(l for _p, l, _h in occ)
    hi = max(h for _p, _l, h in occ)
    return (lo, hi) if (lo, hi) != (1, 1) else None


def main():
    con = sqlite3.connect(SRC)
    cur = con.cursor()

    names = {}
    for tbl in ("creature_template", "gameobject_template",
                "item_template", "area_template"):
        names[tbl] = {r[0]: r[1] for r in cur.execute(
            f"select entry, name from {tbl}")}

    # reference_loot_template preloaded — every table references it
    refs = {}
    for entry, item, ch, lo, hi in cur.execute(
            "select entry, item, ChanceOrQuestChance, mincountOrRef,"
            " maxcount from reference_loot_template where " + PATCH
            + " and condition_id = 0 and ChanceOrQuestChance > 0"):
        refs.setdefault(entry, {}) \
            .setdefault(item, []).append((ch / 100.0, lo, hi))

    items = {}

    def put(item, src, name, occ, via):
        r = merged_rate(occ)
        if r <= 0:
            return
        row = {"src": src, "name": name or "#" + src[1:],
               "chance": round(r * 100, ROUND), "via": via}
        q = merged_qty(occ)
        if q:
            row["qty"] = [q[0], q[1]]
        items.setdefault(item, []).append(row)

    # creature kill / pickpocket / skinning — one loot-id column each;
    # all land on the c<> key so live capture matures the same bucket.
    # id lists fetchall'd FIRST — a nested execute() on the same
    # cursor silently ends the outer iteration
    for table, linkcol, via in (
            ("creature_loot_template", "loot_id", "kill"),
            ("pickpocketing_loot_template", "pickpocket_loot_id", "pp"),
            ("skinning_loot_template", "skinning_loot_id", "skin")):
        tids = [r[0] for r in cur.execute(
            f"select distinct {linkcol} from creature_template "
            f"where {linkcol} > 0").fetchall()]
        tables = {tid: template(cur, refs, table, tid)
                  for tid in tids}
        for cid, tid in cur.execute(
                f"select entry, {linkcol} from creature_template "
                f"where {linkcol} > 0").fetchall():
            occ = tables.get(tid)
            if not occ:
                continue
            nm = names["creature_template"].get(cid)
            for it, oc in occ.items():
                put(it, f"c{cid}", nm, oc, via)

    # gameobject chests (type 3): data1 = loot template id
    tids = [r[0] for r in cur.execute(
        "select distinct data1 from gameobject_template "
        "where type = 3 and data1 > 0").fetchall()]
    tables = {tid: template(cur, refs, "gameobject_loot_template",
                            tid) for tid in tids}
    for oid, tid, nm in cur.execute(
            "select entry, data1, name from gameobject_template "
            "where type = 3 and data1 > 0").fetchall():
        occ = tables.get(tid)
        if occ:
            for it, oc in occ.items():
                put(it, f"o{oid}", nm, oc, "loot")

    # container items — item_loot_template keyed by the item's entry
    for tid in [r[0] for r in cur.execute(
            "select distinct entry from item_loot_template").fetchall()]:
        occ = template(cur, refs, "item_loot_template", tid)
        nm = names["item_template"].get(tid)
        for it, oc in occ.items():
            put(it, f"i{tid}", nm, oc, "cont")

    # fishing — entry is the zone/area id
    for tid in [r[0] for r in cur.execute(
            "select distinct entry from fishing_loot_template").fetchall()]:
        occ = template(cur, refs, "fishing_loot_template", tid)
        nm = names["area_template"].get(tid)
        for it, oc in occ.items():
            put(it, f"f{tid}", nm, oc, "fish")

    # disenchant brackets — label from the fodder ilvl band
    fodder = {}
    for grp, ilvl in cur.execute(
            "select disenchant_id, item_level from item_template "
            "where disenchant_id > 0").fetchall():
        f = fodder.setdefault(grp, [999, 0])
        f[0] = min(f[0], ilvl)
        f[1] = max(f[1], ilvl)
    for grp in [r[0] for r in cur.execute(
            "select distinct entry from disenchant_loot_template").fetchall()]:
        occ = template(cur, refs, "disenchant_loot_template", grp)
        lo, hi = fodder.get(grp, (0, 0))
        nm = f"Disenchant ilvl {lo}-{hi}" if lo else f"Disenchant #{grp}"
        for it, oc in occ.items():
            put(it, f"d{grp}", nm, oc, "de")

    # --- cap + emit ---
    out = {}
    for it, rows_ in items.items():
        # same name+rate collapses (different template entries,
        # identical display) — keep the first srcKey
        seen = set()
        dedup = []
        for r in sorted(rows_, key=lambda r: -r["chance"]):
            k = (r["name"], r["chance"], r["via"])
            if k in seen:
                continue
            seen.add(k)
            dedup.append(r)
        if len(dedup) > KEEP:
            dedup = [r for r in dedup if r["chance"] >= FLOOR][:KEEP]
        if dedup:
            out[str(it)] = dedup

    OUT.write_text(json.dumps(out, separators=(",", ":"),
                            ensure_ascii=False), encoding="utf-8")
    print(f"{OUT.name}: {len(out)} items, "
          f"{sum(len(v) for v in out.values())} sources, "
          f"{OUT.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
