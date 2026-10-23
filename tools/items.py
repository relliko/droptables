"""
The item index for droptables' search window (data/items.lua): for each item, the mobs that drop it
and the mobs it can be stolen from, with each mob's name, zone, level range and NM flag. The chances
themselves come from the zone's loot file at run time (loot.lua), so they follow your TH.

Mob names are the game's own, read from each zone's entity name DAT (Ashita's libs/ffxi/dats/npcs.lua
says which file; records of 32 bytes: a 28-byte name, then the server id), because Phoenix's template
keys aren't names (Jelly_KT_GM). Without the game files, the template key is tidied up instead.
Only spawns the server places count (a spawn with no position just reserves its id for scripts).
"""

import re
import struct
from pathlib import Path

PLACED = ("at", "region", "path", "circuit")
TIDY = re.compile(r"_(fished|\d+|[A-Z]{1,3}(_[A-Z]{1,3})*)$")


class DatNames:
    """Server id -> the game's name for that mob, read per zone from the client's DATs."""

    def __init__(self, ffxi, npcs_lua):
        self.files, self.cache = {}, {}
        if ffxi is not None and npcs_lua is not None and Path(npcs_lua).is_file():
            for zone, path in re.findall(r"\[(\d+)\]\s*=\s*'([^']+)'", Path(npcs_lua).read_text(encoding="utf-8")):
                self.files[int(zone)] = Path(ffxi) / path.lstrip("/")
        self.used = 0

    def zone(self, zone):
        if zone not in self.cache:
            names = {}
            path = self.files.get(zone)
            if path is not None and path.is_file():
                data = path.read_bytes()
                for i in range(0, len(data) - 31, 32):
                    name = data[i:i + 28].split(b"\0")[0].decode("latin1")
                    names[struct.unpack("<I", data[i + 28:i + 32])[0]] = name
            self.cache[zone] = names
        return self.cache[zone]

    def name(self, zone, ids, template):
        names = self.zone(zone)
        for i in ids:
            if names.get(i):
                self.used += 1
                return names[i]
        tidy = template
        while TIDY.search(tidy):
            tidy = TIDY.sub("", tidy)
        return tidy.replace("_", " ")


class Index:
    def __init__(self):
        self.mobs = {}   # [zone] = { [template] = { n =, lv =, nm =, fished = } }
        self.drops = {}  # [item] = { (zone, template), ... }
        self.steal = {}

    def add_zone(self, zone, spawns, templates, keep, names):
        """keep: the zone's converted loot templates (gen_loot.convert_template)."""
        ids, levels = {}, {}
        for mid, sp in spawns.items():
            sp = sp or {}
            name = sp.get("template")
            if name not in keep or not any(k in sp for k in PLACED):
                continue
            ids.setdefault(name, []).append(int(mid))
            lv = sp.get("level")
            if isinstance(lv, list) and len(lv) == 2:
                lo, hi = levels.get(name, (255, 0))
                levels[name] = (min(lo, int(lv[0])), max(hi, int(lv[1])))
        for name, mids in ids.items():
            t = keep[name]
            types = templates[name].get("type") or []
            types = [types] if isinstance(types, str) else types
            m = {"n": names.name(zone, sorted(mids), name)}
            if name in levels:
                m["lv"] = list(levels[name])
            if t["nm"]:
                m["nm"] = True
            if "fished" in types:
                m["fished"] = True
            self.mobs.setdefault(zone, {})[name] = m
            for d in t["drops"]:
                for i in ([d["i"]] if "i" in d else [g[0] for g in d["g"]]):
                    if i != 0:
                        self.drops.setdefault(i, set()).add((zone, name))
            for i in t["steal"]:
                if i != 0:
                    self.steal.setdefault(i, set()).add((zone, name))

    def write(self, path, header, lua_value):
        out = [header, "return {",
               "-- [zone] = { [loot template] = { n = the game's name, lv = { lowest, highest }, nm =, fished = } }",
               "mobs = {"]
        for zone in sorted(self.mobs):
            parts = []
            for name in sorted(self.mobs[zone]):
                m = self.mobs[zone][name]
                f = ["n=%s" % lua_value(m["n"])]
                if "lv" in m:
                    f.append("lv={%d,%d}" % tuple(m["lv"]))
                if m.get("nm"):
                    f.append("nm=true")
                if m.get("fished"):
                    f.append("fished=true")
                parts.append("[%s]={%s}" % (lua_value(name), ",".join(f)))
            out.append("[%d]={%s}," % (zone, ",".join(parts)))
        out.append("},")
        for key, table in (("drops", self.drops), ("steal", self.steal)):
            out.append("-- [item id] = { zone, loot template, zone, loot template, ... }")
            out.append("%s = {" % key)
            for i in sorted(table):
                flat = []
                for zone, name in sorted(table[i]):
                    flat += [str(zone), lua_value(name)]
                out.append("[%d]={%s}," % (i, ",".join(flat)))
            out.append("},")
        out.append("}")
        path.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
