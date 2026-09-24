#!/usr/bin/env python3
"""Generates DuoDS/Resources/PSP-Boxart-Names.json: PSP disc ID -> libretro-thumbnails box-art name.

Sources (facts only, no images are bundled):
  * Serial -> Redump name: libretro-database `metadat/redump/Sony - PlayStation Portable.dat`
    https://raw.githubusercontent.com/libretro/libretro-database/master/metadat/redump/Sony%20-%20PlayStation%20Portable.dat
  * Existing box-art files: the git tree of github.com/libretro-thumbnails/Sony_-_PlayStation_Portable
    (`Named_Boxarts/<name>.png`, served by https://thumbnails.libretro.com/Sony%20-%20PlayStation%20Portable/Named_Boxarts/).

libretro names thumbnails after the playlist label with `&*/:`<>?\\|"` replaced by `_` (verified: "Harvest Moon -
Boy _ Girl (USA).png" is 200, the `&` spelling 404). Many thumbnails carry an older Redump name (other version
tag / language list), so each serial is matched against the files that really exist:
  1. an escaped Redump name of that serial that exists verbatim;
  2. a file with the same title + region group (first parenthesis), closest extra tags, no Beta/Proto/Demo;
  3. the same title in another region (USA > World > Europe > rest), so the game at least shows its own art.
Serials without any match are left out (the app then renders a placeholder insert).

Usage:  python3 generate_psp_names.py [--dat FILE] [--tree FILE] [--out FILE]
(without --dat/--tree the two inputs are downloaded).
"""
import argparse
import collections
import json
import os
import re
import sys
import urllib.request

DAT_URL = ("https://raw.githubusercontent.com/libretro/libretro-database/master/metadat/redump/"
           "Sony%20-%20PlayStation%20Portable.dat")
TREE_URL = "https://api.github.com/repos/libretro-thumbnails/Sony_-_PlayStation_Portable/git/trees/master?recursive=1"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "..", "..", "DuoDS", "Resources", "PSP-Boxart-Names.json")
SERIAL = re.compile(r"^[A-Z]{4}-\d{5}$")
BAD_TAGS = re.compile(r"\((Beta|Proto|Demo|Sample|Kiosk)[^)]*\)", re.I)
REGION_RANK = ["USA", "World", "Europe", "Australia", "Asia", "Japan", "Korea"]


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "GameDuo-generator"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read().decode("utf-8")


def escape(name):
    return re.sub(r'[&*/:`<>?\\|"]', "_", name)


def split(name):
    """('Title', '(Region)', ['(tag)', ...])"""
    m = re.match(r"^(.*?) (\([^)]*\))(.*)$", name)
    if not m:
        return name, "", []
    return m.group(1), m.group(2), re.findall(r"\([^)]*\)", m.group(3))


def region_rank(region):
    for i, r in enumerate(REGION_RANK):
        if r in region:
            return i
    return len(REGION_RANK)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dat")
    ap.add_argument("--tree")
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    dat = open(args.dat, encoding="utf-8").read() if args.dat else fetch(DAT_URL)
    tree = json.load(open(args.tree)) if args.tree else json.loads(fetch(TREE_URL))
    if tree.get("truncated"):
        sys.exit("git tree listing is truncated")
    thumbs = sorted(p["path"][len("Named_Boxarts/"):-len(".png")] for p in tree["tree"]
                    if p["path"].startswith("Named_Boxarts/") and p["path"].endswith(".png"))
    thumb_set = set(thumbs)
    by_base = collections.defaultdict(list)
    by_title = collections.defaultdict(list)
    for t in thumbs:
        title, region, _ = split(t)
        by_base[(title, region)].append(t)
        by_title[title].append(t)

    names = collections.defaultdict(list)  # serial -> Redump names, dat order
    current = None
    for line in dat.splitlines():
        m = re.match(r'^\tname "(.*)"$', line)
        if m:
            current = m.group(1)
            continue
        m = re.match(r'^\tserial "(.*)"$', line)
        if m and current:
            for serial in re.split(r"[,\s]+", m.group(1)):
                if SERIAL.match(serial) and current not in names[serial]:
                    names[serial].append(current)

    def clean_first(cands):
        return sorted(cands, key=lambda n: (bool(BAD_TAGS.search(n)), n))

    def pick(serial):
        cands = clean_first(names[serial])
        for n in cands:
            if escape(n) in thumb_set:
                return escape(n)
        for n in cands:
            title, region, tags = split(escape(n))
            options = [t for t in by_base.get((title, region), []) if not BAD_TAGS.search(t)]
            if options:
                return max(options, key=lambda t: (len(set(split(t)[2]) & set(tags)), -len(t), t))
        for n in cands:
            title, _, _ = split(escape(n))
            options = [t for t in by_title.get(title, []) if not BAD_TAGS.search(t)]
            if options:
                return min(options, key=lambda t: (region_rank(split(t)[1]), len(t), t))
        return None

    out = {}
    for serial in sorted(names):
        name = pick(serial)
        if name:
            out[serial] = name
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        f.write("\n")
    print(f"{len(out)} of {len(names)} serials -> {os.path.normpath(args.out)}")


if __name__ == "__main__":
    main()
