"""
Generates droptables' data from the PhoenixXI server's own repository (github.com/phoenixffxi/Phoenix,
a LandSandBoat fork; the live server runs its `live` branch):

    data/loot/<zone id>.lua   mobs by server id, their loot templates, and NPC sell prices
    data/rules.lua            treasure hunter table, trait levels, gear, caps

    python tools/gen_loot.py [--phoenix C:\\code\\Phoenix] [--content rotz,cop,toau] [--report]

How the server builds a mob's drops (read from Phoenix, which matches LandSandBoat here):
- data/zones/<zone>/mobs.yaml: spawns[<server id>] = { template, level }, templates[<name>].loot =
  { drops, steal, despoil }. A drop is { chance, item } or { chance, one_of } (a group: one member
  is picked by weight; a plain list gives each member weight 1; 'nothing' is a member that drops
  nothing). chance is a tier name or a percentage, stored per mille
  (src/map/data/datasets/zones/mobs/dataset.cpp).
- Data modules listed in modules/init.txt patch those files as RFC 7386 merge patches, in order:
  modules/<entry>/zones/<zone>/mobs.yaml (maps merge, lists are replaced whole, null deletes;
  src/map/data/yaml/merge.cpp). Phoenix's era drop removals and its own drop fixes are made this way.
- A template whose content tag names a disabled expansion never spawns (zoneutils.cpp). Phoenix is
  a ToAU-era server, so only RoZ, CoP and ToAU content is on.
- Item names resolve through the item table's names, the lowest id winning a duplicate name
  (xi::items::lookupIdByName, src/map/utils/itemutils.cpp).
- CMobEntity::DropItems (src/map/entities/mob_entity.cpp): an item drops when
  rand(1..10000) <= getDropRate(TH, per mille x 10) x DROP_RATE_MULTIPLIER; a group rolls its
  chance the same way, then picks one member by weight. getDropRate is
  scripts/combat/basic/treasure_hunter.lua: a rate falls into a bracket and is replaced by that
  bracket's entry in the TH table. No enabled module overrides it (checked here on every run).
- A mob's TH is the highest TH of anyone acting on it: capped at 8 for a THF main, 4 otherwise
  (src/map/enmity_container.cpp). TH procs are disabled on PhoenixXI, so it doesn't rise in a fight.
- Beastmen's seals and crystals are added by code, not the loot table (mob_entity.cpp).
- Despoil is left out: it's a level 77 THF ability of Abyssea content, so unusable on this server.
"""

import argparse
import math
import re
import subprocess
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "data"

# Rate tiers, per mille (xi::DropRate).
TIERS = {"always": 1000, "very_common": 240, "common": 150, "uncommon": 100, "rare": 50,
         "very_rare": 10, "super_rare": 5, "ultra_rare": 1}
# Zones past the era: Adoulin and later.
LAST_ZONE = 255
TH_MOD = 303      # Mod::TREASURE_HUNTER
THF = 6


class GenError(Exception):
    pass


def lround(x):
    """C's lround for the non-negative values here: halves round up (Python's round() goes to even)."""
    return int(math.floor(x + 0.5))


def merge_patch(target, patch):
    """RFC 7386: maps merge key by key, null deletes, anything else (lists too) replaces."""
    if not isinstance(patch, dict):
        return patch
    if not isinstance(target, dict):
        target = {}
    out = dict(target)
    for key, value in patch.items():
        if value is None:
            out.pop(key, None)
        else:
            out[key] = merge_patch(out.get(key), value)
    return out


def init_entries(root):
    entries = []
    for line in (root / "modules" / "init.txt").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            entries.append(line.rstrip("/"))
    return entries


def zone_overlays(root, entries, zone):
    return [root / "modules" / e / "zones" / zone / "mobs.yaml" for e in entries
            if (root / "modules" / e / "zones" / zone / "mobs.yaml").is_file()]


def load_zone(root, entries, zone):
    doc = yaml.safe_load((root / "data" / "zones" / zone / "mobs.yaml").read_text(encoding="utf-8")) or {}
    used = []
    for path in zone_overlays(root, entries, zone):
        doc = merge_patch(doc, yaml.safe_load(path.read_text(encoding="utf-8")) or {})
        used.append(path)
    return doc, used


ITEM_ROW = re.compile(
    r"^INSERT INTO `item_basic` VALUES \((\d+),(\d+),'([^']*)','[^']*','[^']*',([^,]+),(\d+),([^,]+),([^,]+),(\d+)\);", re.M)


def read_items(root):
    text = (root / "sql" / "item_basic.sql").read_text(encoding="utf-8")
    rows = ITEM_ROW.findall(text)
    if len(rows) != text.count("INSERT INTO `item_basic`"):
        raise GenError("item_basic.sql: the table layout changed")
    by_name, price = {}, {}
    for itemid, _sub, name, _type, _stack, flags, _ah, sell in rows:
        itemid = int(itemid)
        by_name[name] = min(itemid, by_name.get(name, itemid))
        price[itemid] = False if "@FLAG_NOSALE" in flags else int(sell)
    return by_name, price


def chance(value, where):
    if isinstance(value, str):
        if value not in TIERS:
            raise GenError("%s: unknown chance '%s'" % (where, value))
        return TIERS[value]
    if isinstance(value, (int, float)) and 0 <= value <= 100:
        return lround(value * 10)
    raise GenError("%s: bad chance %r" % (where, value))


def names(value):
    if value is None:
        return []
    return [value] if isinstance(value, str) else list(value)


class Resolver:
    def __init__(self, by_name):
        self.by_name, self.missing = by_name, set()

    def __call__(self, name, where):
        if name == "nothing":
            return 0
        if name not in self.by_name:
            self.missing.add("%s: %s" % (where, name))
            return 0
        return self.by_name[name]


def convert_template(tpl, where, item):
    loot = tpl.get("loot") or {}
    drops = []
    for n, roll in enumerate(loot.get("drops") or []):
        at = "%s drop %d" % (where, n + 1)
        r = chance(roll.get("chance"), at)
        if ("item" in roll) == ("one_of" in roll):
            raise GenError("%s: needs an item or a one_of" % at)
        if "item" in roll:
            drops.append({"r": r, "i": item(roll["item"], at)})
            continue
        one = roll["one_of"]
        if isinstance(one, dict):
            members = [(item(k, at), lround(float(v) * 100)) for k, v in one.items()]
            if sum(w for _, w in members) != 10000:
                raise GenError("%s: one_of shares don't add up to 100" % at)
        else:
            members = [(item(k, at), 1) for k in one]
        drops.append({"r": r, "g": members})
    steal = [item(k, where + " steal") for k in names(loot.get("steal"))]
    types = tpl.get("type") or []
    types = [types] if isinstance(types, str) else types
    return {"nm": "notorious" in types, "drops": drops, "steal": steal}


def scripted_loot(root):
    """(zone folder lower-case, script name) pairs whose Lua adds loot, and families that do."""
    files, families = set(), set()
    for p in (root / "scripts" / "zones").glob("*/mobs/*.lua"):
        if "ITEM_DROPS" in p.read_text(encoding="utf-8", errors="replace"):
            files.add((p.parent.parent.name.lower(), p.stem))
    for p in (root / "scripts" / "mixins" / "families").glob("*.lua"):
        if "ITEM_DROPS" in p.read_text(encoding="utf-8", errors="replace"):
            families.add(p.stem)
    return files, families


def lua_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return "'" + v.replace("\\", "\\\\").replace("'", "\\'") + "'"
    raise TypeError(v)


def write_zone(path, zone, mobs, templates, prices, header):
    out = [header, "return {", "zone = %d," % zone, "mobs = {"]
    for mid in sorted(mobs):
        m = mobs[mid]
        lv = (",lv={%d,%d}" % tuple(m["lv"])) if m.get("lv") else ""
        out.append("[%d]={t=%s%s}," % (mid, lua_value(m["t"]), lv))
    out.append("},")
    out.append("templates = {")
    for name in sorted(templates):
        t = templates[name]
        drops = []
        for d in t["drops"]:
            if "i" in d:
                drops.append("{r=%d,i=%d}" % (d["r"], d["i"]))
            else:
                drops.append("{r=%d,g={%s}}" % (d["r"], ",".join("{%d,%d}" % m for m in d["g"])))
        out.append("[%s]={nm=%s,script=%s,drops={%s},steal={%s}}," % (
            lua_value(name), lua_value(t["nm"]), lua_value(t["script"]), ",".join(drops),
            ",".join(str(i) for i in t["steal"])))
    out.append("},")
    out.append("prices = {%s}," % ",".join("[%d]=%s" % (i, lua_value(prices[i])) for i in sorted(prices)))
    out.append("}")
    path.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")


TH_EXPECT = [
    r"thTier\s*=\s*utils\.clamp\(thTier,\s*0,\s*14\)",
    r"if thDropRate == 10000 then\s*return 10000\s*elseif thDropRate == 0 then\s*return 0",
    r"if thDropRate >= xi\.combat\.treasureHunter\.dropBracketTable\[i\]\[1\] then\s*thBracket = i",
    r"local newDropRate = xi\.combat\.treasureHunter\.treasureHunterTable\[thTier\]\[thBracket\]",
]


def read_rules(root, entries):
    src = (root / "scripts" / "combat" / "basic" / "treasure_hunter.lua").read_text(encoding="utf-8")
    for pattern in TH_EXPECT:
        if not re.search(pattern, src):
            raise GenError("treasure_hunter.lua changed its algorithm (%s); update droptables' model" % pattern)
    for e in entries:
        base = root / "modules" / e
        if base.suffix == ".lua" and base.is_file():
            files = [base]
        elif base.is_dir():
            files = list(base.rglob("*.lua"))
        else:
            files = []
        for f in files:
            if "treasureHunter" in f.read_text(encoding="utf-8", errors="replace"):
                raise GenError("%s overrides treasure hunter; update droptables' model" % f.relative_to(root))
    table = {}
    for th, row in re.findall(r"\[\s*(\d+)\]\s*=\s*\{([\d,\s]+)\}", src.split("dropBracketTable")[0]):
        table[int(th)] = [int(x) for x in row.split(",") if x.strip()]
    brackets = [int(x) for x in re.findall(r"\[\d+\]\s*=\s*\{\s*(\d+)\s*\}", src.split("dropBracketTable")[1].split("getDropRate")[0])]
    if sorted(table) != list(range(15)) or any(len(r) != 7 for r in table.values()) or len(brackets) != 7:
        raise GenError("treasure_hunter.lua: tables not as expected")
    mult = re.search(r"DROP_RATE_MULTIPLIER\s*=\s*([\d.]+)", (root / "settings" / "default" / "map.lua").read_text(encoding="utf-8"))
    traits = []
    for level, value, content in re.findall(
            r"INSERT INTO `traits` VALUES \(\d+,'treasure hunter[^']*',%d,(\d+),\d+,%d,(\d+),(NULL|'[^']*'),\d+\);" % (THF, TH_MOD),
            (root / "sql" / "traits.sql").read_text(encoding="utf-8")):
        if content == "NULL":
            traits.append((int(level), int(value)))
    gear = {int(i): int(v) for i, v in re.findall(r"INSERT INTO `item_mods` VALUES \((\d+),%d,(-?\d+)\)" % TH_MOD,
                                                  (root / "sql" / "item_mods.sql").read_text(encoding="utf-8"))}
    enmity = (root / "src" / "map" / "enmity_container.cpp").read_text(encoding="utf-8")
    caps = re.search(r"std::min<int16>\((\d+), PEntity->getMod\(xi::Mod::TREASURE_HUNTER\)\);.*?"
                     r"GetMJob\(\) != xi::Job::THF\)\s*\{\s*THlevel = std::min<int16>\((\d+),", enmity, re.S)
    if not (mult and traits and gear and caps):
        raise GenError("could not read the multiplier, TH traits, TH gear or TH caps")
    return {"table": table, "brackets": brackets, "multiplier": float(mult.group(1)), "traits": sorted(traits),
            "gear": gear, "cap_thf": int(caps.group(1)), "cap_other": int(caps.group(2))}


def write_rules(path, rules, header):
    out = [header, "return {"]
    out.append("-- getDropRate: a rate (out of 10000) is in bracket b when it is >= brackets[b] (first match);")
    out.append("-- 10000 and 0 are kept. table[TH][b] is the rate it becomes.")
    out.append("brackets = {%s}," % ",".join(str(b) for b in rules["brackets"]))
    out.append("table = {")
    for th in range(15):
        out.append("[%d]={%s}," % (th, ",".join(str(v) for v in rules["table"][th])))
    out.append("},")
    out.append("multiplier = %s," % repr(rules["multiplier"]))
    out.append("-- THF trait: { job level, TH }.")
    out.append("traits = {%s}," % ",".join("{%d,%d}" % t for t in rules["traits"]))
    out.append("cap_thf = %d, cap_other = %d, -- highest TH a THF main / any other main job applies" % (rules["cap_thf"], rules["cap_other"]))
    out.append("procs = false, -- TH procs are disabled on PhoenixXI")
    out.append("-- Equipment with Treasure Hunter: [item id] = TH.")
    out.append("gear = {%s}," % ",".join("[%d]=%d" % (i, v) for i, v in sorted(rules["gear"].items())))
    out.append("}")
    path.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")


def phoenix_commit(root):
    try:
        head = subprocess.run(["git", "-C", str(root), "log", "-1", "--format=%h %cs"], capture_output=True, text=True, check=True).stdout.strip()
        branch = subprocess.run(["git", "-C", str(root), "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        return "%s (%s)" % (head, branch)
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def generate(root, out, content, report=False):
    entries = init_entries(root)
    by_name, price = read_items(root)
    item = Resolver(by_name)
    rules = read_rules(root, entries)
    script_files, script_families = scripted_loot(root)
    commit = phoenix_commit(root)
    header = "-- Generated by tools/gen_loot.py from PhoenixXI %s. Do not edit; run the script again." % commit
    (out / "loot").mkdir(parents=True, exist_ok=True)
    for old in (out / "loot").glob("*.lua"):
        old.unlink()
    stats = {"zones": 0, "mobs": 0, "templates": 0, "scripted": [], "skipped_content": 0, "overlays": 0}
    for folder in sorted((root / "data" / "zones").iterdir()):
        if not (folder / "mobs.yaml").is_file() or folder.name.startswith("abyssea_"):
            continue
        doc, used = load_zone(root, entries, folder.name)
        spawns, templates = doc.get("spawns") or {}, doc.get("templates") or {}
        zone = None
        mobs, keep = {}, {}
        for mid, sp in spawns.items():
            mid = int(mid)
            zone = (mid >> 12) & 0xFFF
            name = (sp or {}).get("template")
            tpl = templates.get(name)
            if tpl is None:
                continue
            tag = tpl.get("content")
            if tag is not None and str(tag).lower() not in content:
                stats["skipped_content"] += 1
                continue
            if not (tpl.get("loot") or {}):
                continue
            lv = sp.get("level")
            mobs[mid] = {"t": name, "lv": lv if isinstance(lv, list) and len(lv) == 2 else None}
            if name not in keep:
                t = convert_template(tpl, "%s/%s" % (folder.name, name), item)
                species = str(tpl.get("species") or "")
                t["script"] = (folder.name.lower(), sp.get("script") or name) in script_files or \
                              (folder.name.lower(), name) in script_files or species in script_families
                keep[name] = t
            elif (folder.name.lower(), sp.get("script") or name) in script_files:
                keep[name]["script"] = True
        if zone is None or zone > LAST_ZONE or not mobs:
            continue
        items = set()
        for t in keep.values():
            for d in t["drops"]:
                items.update([d["i"]] if "i" in d else [m[0] for m in d["g"]])
            items.update(t["steal"])
        items.discard(0)
        write_zone(out / "loot" / ("%d.lua" % zone), zone, mobs, keep, {i: price.get(i, 0) for i in items}, header)
        stats["zones"] += 1
        stats["mobs"] += len(mobs)
        stats["templates"] += len(keep)
        stats["overlays"] += len(used)
        stats["scripted"] += ["%s/%s" % (folder.name, n) for n, t in keep.items() if t["script"]]
    if item.missing:
        raise GenError("unknown items:\n  " + "\n  ".join(sorted(item.missing)))
    write_rules(out / "rules.lua", rules, header)
    print("wrote %d zones, %d mobs, %d loot templates (%d overlay files applied, %d spawns skipped for disabled content)"
          % (stats["zones"], stats["mobs"], stats["templates"], stats["overlays"], stats["skipped_content"]))
    if report:
        print("templates with loot added by a script (%d): %s" % (len(stats["scripted"]), ", ".join(stats["scripted"])))
        print("TH gear items: %d; traits: %s; caps THF %d / other %d; multiplier %s" % (
            len(rules["gear"]), rules["traits"], rules["cap_thf"], rules["cap_other"], rules["multiplier"]))
    return stats


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--phoenix", type=Path, default=Path(r"C:\code\Phoenix"), help="Phoenix server checkout (live branch)")
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--content", default="rotz,cop,toau", help="expansions whose content is enabled")
    ap.add_argument("--report", action="store_true")
    args = ap.parse_args(argv)
    try:
        generate(args.phoenix, args.out, {c.strip().lower() for c in args.content.split(",")}, args.report)
    except GenError as e:
        print("error:", e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
