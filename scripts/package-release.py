#!/usr/bin/env python
"""Package a GoblinMind release zip into dist/.

Canonical layout (must match scripts/sync-addons.bat):
    GoblinMind/            addons/GoblinMind/**           (the addon)
    GoblinMind/brain/      brain/goblin_brain.py
                           brain/goblin-watch.bat         (the feed watcher)
    GoblinMind_Data/       addons/GoblinMind_Data/**      (generated DB)

Usage: python scripts/package-release.py <version>
       e.g.  python scripts/package-release.py 0.2.0-alpha
"""
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDONS = ("GoblinMind", "GoblinMind_Data")
BRAIN_FILES = ("goblin_brain.py", "goblin-watch.bat", "vendor_buy.json",
               "goblin_server.py", "install.py", "install.bat",
               "feeds.example.json")


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: package-release.py <version>")
    version = sys.argv[1]
    out = os.path.join(ROOT, "dist", f"GoblinMind-{version}.zip")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for addon in ADDONS:
            root = os.path.join(ROOT, "addons", addon)
            for dp, _, fns in os.walk(root):
                for fn in sorted(fns):
                    p = os.path.join(dp, fn)
                    z.write(p, os.path.relpath(p, os.path.join(ROOT, "addons")))
        for fn in BRAIN_FILES:
            z.write(os.path.join(ROOT, "brain", fn), f"GoblinMind/brain/{fn}")
    print(f"{out} — {len(zipfile.ZipFile(out).namelist())} entries")


if __name__ == "__main__":
    main()
