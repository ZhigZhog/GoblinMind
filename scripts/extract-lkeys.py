#!/usr/bin/env python3
"""extract-lkeys.py — rebuild GoblinMind's enUS locale table.

Scans every addon lua file for literals that reach the localizer:
  - L("x") / LT("x") / GM.L("x") / (GM.L or id)("x") calls
  - string args to the LT()-backed widget helpers (Btn, ActionBtn,
    MkBtn, Segment, EditBox, ColPanel, TitledPanel, ListPanel and
    the per-file local Panel wrappers — the title is always a
    string arg)
  - title=/hint=/label= option literals (Window, ItemSlot,
    PopupMenu entries)
  - {"key","LABEL"} / {"LABEL","key"} def-pairs: one pure-lowercase
    element marks the key, the other is taken as the label

Rewrites the RegisterLocale("GoblinMind", "enUS") block in
addons/GoblinMind/GoblinUIHost.lua from scratch, sorted
case-insensitively — extraction is the source of truth, so junk from
older runs self-heals. Filters drop code identifiers (camelCase,
SCREAMING_SNAKE, %format tokens, fragments with parens or ..),
style names, and colour-coded strings.

Run after adding UI strings:  python scripts\\extract-lkeys.py
Anything still missed prints "GoblinUI unregistered L key" in game —
add it here or register it by hand.
"""

import re
import glob
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ADDON = ROOT / "addons" / "GoblinMind"
HOST = ADDON / "GoblinUIHost.lua"

# style/color names that legitimately appear inside helper calls —
# they are GM.Panel fills and GM.RGB keys, not display text
STYLE_WORDS = {
    "contHigh", "contLow", "contLowest", "contMedium", "contHighest",
    "accent", "outlineVar", "outline", "secondary", "textDim", "text",
    "warn", "pos", "err",
    # WoW API vocabulary swept in from code nested inside helper
    # args — anchors, draw layers, widget classes, layout keywords,
    # lua keywords. Never display text.
    "TOP", "TOPLEFT", "TOPRIGHT", "BOTTOM", "BOTTOMLEFT",
    "BOTTOMRIGHT", "LEFT", "RIGHT", "CENTER",
    "BACKGROUND", "BORDER", "ARTWORK", "OVERLAY", "HIGHLIGHT",
    "Frame", "Button", "EditBox", "Slider", "CheckButton",
    "FontString", "Texture", "ScrollFrame", "StatusBar", "Cooldown",
    "Model", "GameTooltip",
    "fill", "fit", "wrap", "auto", "grow",
    "function", "local", "return", "end", "self", "true", "false",
    "nil", "and", "or", "not",
    # URL fragments and pure-format strings
    "https://", "http://",
}

HELPER_RE = re.compile(
    r'(?:^|[^\w_])'
    r'(?:Btn|ActionBtn|MkBtn|Segment|ColPanel|TitledPanel|ListPanel|'
    r'Panel|FilterToggle|EditBox)\s*\('
)


def helper_args(src):
    """Yield the arg-list text of every widget-helper call.

    A regex arg capture ([^)]*) truncates at the first ')' — which
    kills any title that CONTAINS parens ("REVENUE — RESALE
    (BUY→SELL MARGIN)" was silently unregistered for exactly this).
    Scan char-by-char instead: track quote state so parens inside
    string literals don't count, and stop at depth 0.
    """
    for m in HELPER_RE.finditer(src):
        i = m.end()
        depth, j, q = 1, i, None
        while j < len(src) and depth:
            c = src[j]
            if q:
                if c == "\\":
                    j += 1
                elif c == q:
                    q = None
            elif c == '"' or c == "'":
                q = c
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            j += 1
        yield src[i:j - 1]
DIRECT_L = re.compile(r'(?:\bL|\bLT|GM\.L)\s*\(\s*"((?:[^"\\]|\\.)*)"')
OR_LIT = re.compile(r'\bend\)\s*\(\s*"((?:[^"\\]|\\.)*)"')
KV_OPT = re.compile(r'(?:title|hint|label)\s*=\s*"((?:[^"\\]|\\.)*)"')
PAIR = re.compile(r'\{\s*"((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"')
ANY_LIT = re.compile(r'"((?:[^"\\]|\\.)*)"')
LOWKEY = re.compile(r'^[a-z]+$')

# code smells — never display text:
#   \.\.\s*\w   concat fragment ("foo" .. bar)
#   [\w]+\.[\w]+ dotted identifier (table.concat, GM.Foo) — note the
#               real-hint form "id…" never has word chars BOTH sides
#   _           identifier/event names (AUCTION_HOUSE_SHOW, commits_filled)
#   %[a-zA-Z%]  format tokens (%s, %d, %MKT) — a bare trailing % is fine
CODE = re.compile(r'\.\.\s*\w|[\w]+\.[\w]+|_|%[a-zA-Z%]')
# one-token mixed-case identifiers: matsOnly, qtyTotal, IsNPCCrafting
CAMEL = re.compile(r'^[A-Za-z]*(?:[a-z][A-Z]|[A-Z][a-z]+[A-Z])\w*$')


def plausible(s):
    return (
        len(s) > 1
        and re.search(r'[a-zA-Z]', s)
        and '|' not in s
        and '\\' not in s
        and not CODE.search(s)
        and s not in STYLE_WORDS
        and not s.startswith(")")  # concat fragment, not a label
        and not re.fullmatch(r'[\d.,:%/\-+ ]+', s)
        and not (' ' not in s and CAMEL.match(s))
    )


def collect():
    keys = set()
    for path in glob.glob(str(ADDON / "*.lua")):
        src = open(path, encoding="utf-8").read()
        for rx in (DIRECT_L, OR_LIT, KV_OPT):
            keys.update(m.group(1) for m in rx.finditer(src))
        for m in PAIR.finditer(src):
            a, b = m.groups()
            if LOWKEY.match(a) and re.search(r'[A-Z]', b):
                keys.add(b)
            elif LOWKEY.match(b) and re.search(r'[A-Z]', a):
                keys.add(a)
        for args in helper_args(src):
            keys.update(x.group(1) for x in ANY_LIT.finditer(args))
    return {k for k in keys if plausible(k)}


def main():
    keys = sorted(collect(), key=str.lower)
    src = HOST.read_text(encoding="utf-8")
    m = re.search(
        r'(lib:RegisterLocale\("GoblinMind", "enUS", \{\n)(.*?)(\n\}\))',
        src, re.S)
    if not m:
        sys.exit("RegisterLocale block not found in GoblinUIHost.lua")
    old = set(re.findall(r'\t\["([^"]+)"\]', m.group(2)))
    new = set(keys)
    esc = lambda k: k.replace('\\', '\\\\').replace('"', '\\"')
    body = ''.join(f'\t["{esc(k)}"] = "{esc(k)}",\n' for k in keys)
    HOST.write_text(src[:m.start(2)] + body + src[m.end(2):],
                    encoding="utf-8")
    print(f"{len(keys)} keys — "
          f"{len(new - old)} added, {len(old - new)} dropped")
    for k in sorted(new - old, key=str.lower):
        print("  + " + k.encode("ascii", "replace").decode())
    for k in sorted(old - new, key=str.lower):
        print("  - " + k.encode("ascii", "replace").decode())


if __name__ == "__main__":
    main()
