"""
Mob info for droptables' frame (data/info/<zone id>.lua): how a mob aggros, what it resists, its
TP moves and spells, and its respawn. Called by gen_loot.py; read from Phoenix the way the server
builds a mob (src/map/utils/zoneutils.cpp InsertMobs, mobutils::ApplySpecies):

- Attributes merge down a chain: ecosystem -> family -> species (data/ecosystems.yaml) -> the
  zone's template -> the spawn. Each field replaces the one above it; resists, mods and mob mods
  merge key by key (src/map/data/shared_types/mob_attributes/dataset.cpp).
- Aggro (CMobController::CanAggroTarget / CanDetectTarget, CZoneEntities::tapMobAggro): a mob
  aggros only when aggressive (or mob mod always_aggro), and only a player it doesn't check Too
  Weak, unless that player is resting or the mob has always_aggro. Sight is 15 yalms in front of
  it (Invisible stops it), hearing 8 (Sneak), magic 20 (casting a spell that costs MP); low HP
  (under 75%) and job abilities/weapon skills only within 20. True detection sees through both.
  An ambusher (behaviour aggro_ambush) aggros anyone without Sneak within 3. Mob mods sight_range,
  sound_range, magic_range and detection override those.
- resists.dmg_physical/dmg_magic are damage taken: 1 + value/10000 (battleutils). rank_element and
  rank_status are resistance ranks (-3 to 11) that scale magic evasion
  (scripts/combat/basic/magic_hit_rate.lua).
- Charmable is cleared for NMs, event, fished and battlefield mobs (ApplySpecies).
- TP moves: the template's skill_list_id in sql/mob_skill_lists.sql -> sql/mob_skills.sql. Spells:
  its spells list, or spell_list_id in sql/mob_spell_lists.sql (with a level range per spell).
  Phoenix's module SQL changes to those tables are applied in the database tool's order.
- A mob's Lua script can change any of this when it spawns; templates whose script does are marked.
"""

import re

ELEMENTS = ["fire", "ice", "wind", "earth", "thunder", "water", "light", "dark"]
STATUSES = ["paralyze", "bind", "silence", "slow", "poison", "light_sleep", "dark_sleep", "blind", "stun", "gravity"]
PHYSICAL = ["slashing", "piercing", "blunt", "h2h"]
DETECTS = {"sight": 0x001, "hearing": 0x002, "lowhp": 0x004, "magic": 0x020, "ability": 0x040, "scent": 0x100}
SPECIAL = {"notorious", "event", "fished", "battlefield"}
# Lua calls in a mob's script that change what the frame shows.
SCRIPT_CHANGES = re.compile(r"\b(addImmunity|setMobMod|setMod|addMod|setBehavior|setAggressive|setTrueDetection|"
                            r"setMobSkillList|setSpellList|setLinkRadius)\s*\(")


def merge(a, b):
    if isinstance(a, dict) and isinstance(b, dict):
        out = dict(a)
        for k, v in b.items():
            out[k] = merge(out.get(k), v)
        return out
    return a if b is None else b


def read_species(root):
    import yaml
    doc = yaml.safe_load((root / "data" / "ecosystems.yaml").read_text(encoding="utf-8"))
    species = {}
    for eco_name, eco in (doc.get("ecosystems") or {}).items():
        for fam_name, fam in ((eco or {}).get("families") or {}).items():
            chain = merge((eco or {}).get("attributes") or {}, (fam or {}).get("attributes") or {})
            for sp_name, sp in ((fam or {}).get("species") or {}).items():
                species[sp_name] = (eco_name, fam_name, merge(chain, (sp or {}).get("attributes") or {}))
    return species


SKILL_ROW = re.compile(r"INSERT INTO `mob_skills` VALUES \((\d+),\d+,'([^']*)',(\d+),")
SKILL_LIST_ROW = re.compile(r"INSERT INTO `mob_skill_lists` VALUES \('([^']*)',(\d+),(\d+)\)")
SPELL_LIST_ROW = re.compile(r"INSERT INTO `mob_spell_lists` VALUES \('([^']*)',(\d+),(\d+),(\d+),(\d+)\)")
SPELL_ROW = re.compile(r"INSERT INTO `spell_list` VALUES \((\d+),'([^']*)'")
SPELL_LEVEL = re.compile(r"UPDATE `mob_spell_lists` SET `(min_level|max_level)`\s*=\s*(\d+)\s+WHERE `spell_list_id`\s*=\s*(\d+)\s+AND `spell_id`\s*=\s*(\d+)")
SPELL_DELETE = re.compile(r"DELETE FROM `mob_spell_lists` WHERE `spell_list_id`\s*=\s*(\d+)\s+AND `spell_id`\s*=\s*(\d+)")
SKILL_LIST_DELETE = re.compile(r"DELETE FROM `mob_skill_lists` WHERE `skill_list_name`\s*=\s*'([^']*)'")
SKILL_DELETE = re.compile(r"DELETE FROM `mob_skills` WHERE `mob_skill_id`\s*=\s*(\d+)")


class Lists:
    """TP move and spell lists, with the enabled modules' SQL changes applied."""

    def __init__(self, root, module_files):
        sql = lambda name: (root / "sql" / name).read_text(encoding="utf-8", errors="replace")
        texts = [sql("mob_skills.sql"), sql("mob_skill_lists.sql"), sql("mob_spell_lists.sql")]
        self.skills = {}         # [skill id] = (name, aoe)
        self.skill_lists = {}    # [list id] = [(list name, skill id)]
        self.spell_lists = {}    # [list id] = {spell id: [min, max]}
        self.spell_names = {int(i): n for i, n in SPELL_ROW.findall(sql("spell_list.sql"))}
        for path in module_files:
            texts.append(path.read_text(encoding="utf-8-sig", errors="replace"))
        for text in texts:
            # Statements apply in file order: inserts, then that file's changes.
            for i, name, aoe in SKILL_ROW.findall(text):
                self.skills[int(i)] = (name, int(aoe))
            for name, lid, sid in SKILL_LIST_ROW.findall(text):
                self.skill_lists.setdefault(int(lid), []).append((name, int(sid)))
            for lname, lid, sid, lo, hi in SPELL_LIST_ROW.findall(text):
                if lname.startswith("DEFAULT_"):
                    continue  # placeholder lists (a song or a lullaby "needs to be a buff")
                self.spell_lists.setdefault(int(lid), {})[int(sid)] = [int(lo), int(hi)]
            for col, value, lid, sid in SPELL_LEVEL.findall(text):
                entry = self.spell_lists.get(int(lid), {}).get(int(sid))
                if entry is not None:
                    entry[0 if col == "min_level" else 1] = int(value)
            for lid, sid in SPELL_DELETE.findall(text):
                self.spell_lists.get(int(lid), {}).pop(int(sid), None)
            for name in SKILL_LIST_DELETE.findall(text):
                for lid in self.skill_lists:
                    self.skill_lists[lid] = [e for e in self.skill_lists[lid] if e[0] != name]
            for sid in SKILL_DELETE.findall(text):
                self.skills.pop(int(sid), None)
        self.by_spell_name = {n: i for i, n in sorted(self.spell_names.items(), reverse=True)}

    def tp_moves(self, list_id, kinds=()):
        """[(name, aoe)]. The server's names can end in the family or species they belong to
        (baleful_gaze_cockatrice), a variant tag (_dynamis) or a number; those endings are left off."""
        out, seen = [], set()
        drop = {"dynamis"} | {w for k in kinds for w in str(k).lower().split("_")}
        for _, sid in self.skill_lists.get(list_id or 0, []):
            if sid not in self.skills:
                continue
            name, aoe = self.skills[sid]
            words = name.split("_")
            while len(words) > 1 and (words[-1] in drop or words[-1].isdigit()):
                words.pop()
            label = " ".join(w.capitalize() for w in words)
            if label not in seen:
                seen.add(label)
                out.append((label, aoe))
        return out

    def spells(self, tpl, lv):
        """[(spell id, min level, max level)] the template can cast somewhere in its level range."""
        if tpl.get("spells"):
            return [(self.by_spell_name[n], 1, 255) for n in tpl["spells"] if n in self.by_spell_name]
        lo, hi = lv
        out = []
        for sid, (a, b) in sorted(self.spell_lists.get(tpl.get("spell_list_id") or 0, {}).items()):
            if a <= hi and b >= lo:
                out.append((sid, a, b))
        return out


def scripted_changes(root):
    """(zone folder lower-case, script name) pairs whose mob script changes resists, aggro or lists."""
    out = set()
    for p in (root / "scripts" / "zones").glob("*/mobs/*.lua"):
        if SCRIPT_CHANGES.search(p.read_text(encoding="utf-8", errors="replace")):
            out.add((p.parent.parent.name.lower(), p.stem.lower()))
    return out


def names(value):
    if value is None:
        return []
    return [value] if isinstance(value, str) else list(value)


def template_info(name, tpl, species, lists, lv, scripted):
    eco, fam, attrs = species.get(tpl.get("species"), ("", "", {}))
    a = merge(attrs, tpl.get("attributes") or {})
    types = set(names(tpl.get("type")))
    beh = a.get("behaviors") or {}
    mm = a.get("mob_mods") or {}
    res = a.get("resists") or {}
    roam = set(names(tpl.get("roam")))
    det = [d for d in names(a.get("detects")) if d in DETECTS]
    if "detection" in mm:
        det = [d for d, bit in DETECTS.items() if int(mm["detection"]) & bit]
    info = {
        "family": fam, "eco": eco,
        "nm": "notorious" in types,
        "aggro": bool(beh.get("aggressive")) or int(mm.get("always_aggro", 0)) > 0,
        "always": int(mm.get("always_aggro", 0)) > 0,
        "noaggro": int(mm.get("no_aggro", 0)) > 0,
        "link": bool(beh.get("links")) and int(mm.get("no_link", 0)) == 0,
        "truesight": bool(beh.get("true_detection")),
        "det": det,
        "ambush": "aggro_ambush" in names(beh.get("flags")),
        "follow": "follow" in roam,
        "sight": int(mm.get("sight_range", 15)), "sound": int(mm.get("sound_range", 8)), "magic": int(mm.get("magic_range", 20)),
        "element": a.get("element") or "",
        "jobs": [j for j in names(a.get("jobs"))],
        "charm": bool(a.get("charmable")) and not (types & SPECIAL),
        "respawn": int((a.get("spawn") or {}).get("respawn") or 0),
        "window": None,
        "script": scripted,
    }
    window = (a.get("spawn") or {}).get("window") or {}
    if window.get("start") is not None and window.get("end") is not None:
        info["window"] = [int(window["start"]), int(window["end"])]
    phys = res.get("dmg_physical") or {}
    info["phys"] = {k: 100 + int(phys[k]) // 100 for k in PHYSICAL if int(phys.get(k) or 0) != 0}
    mag = res.get("dmg_magic") or {}
    info["mdmg"] = {k: 100 + int(mag[k]) // 100 for k in ["all"] + ELEMENTS if int(mag.get(k) or 0) != 0}
    info["el"] = {k: int((res.get("rank_element") or {}).get(k) or 0) for k in ELEMENTS}
    info["st"] = {k: int((res.get("rank_status") or {}).get(k) or 0) for k in STATUSES}
    info["immune"] = names(res.get("immune_status"))
    info["tp"] = lists.tp_moves(tpl.get("skill_list_id"), (fam, tpl.get("species") or ""))
    info["spells"] = lists.spells(tpl, lv)
    return info


def lua(v):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return "'" + v.replace("\\", "\\\\").replace("'", "\\'") + "'"
    if isinstance(v, (list, tuple)):
        return "{" + ",".join(lua(x) for x in v) + "}"
    if isinstance(v, dict):
        return "{" + ",".join("%s=%s" % (k, lua(v[k])) for k in v) + "}"
    raise TypeError(v)


# Left out of the files when a template has them; the addon reads a missing field as this.
DEFAULTS = {"sight": 15, "sound": 8, "magic": 20, "respawn": 0}


def compact(info):
    out = {}
    for k, v in info.items():
        if v is None or v is False or v == [] or v == {} or v == "" or DEFAULTS.get(k) == v:
            continue
        if isinstance(v, dict) and k in ("el", "st"):
            v = {e: r for e, r in v.items() if r != 0}
            if not v:
                continue
        out[k] = v
    return out


def write_zone(path, zone, mobs, templates, header):
    out = [header, "return {", "zone = %d," % zone, "mobs = {"]
    for mid in sorted(mobs):
        out.append("[%d]=%s," % (mid, lua(mobs[mid])))
    out.append("},")
    out.append("templates = {")
    for name in sorted(templates):
        out.append("[%s]=%s," % (lua(name), lua(compact(templates[name]))))
    out.append("},")
    out.append("}")
    path.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")


def zone_info(folder, doc, content, species, lists, scripted):
    """The zone's spawns ({ t =, lv =, r = }) and its templates' info, or None for a zone with no mobs."""
    spawns, templates = doc.get("spawns") or {}, doc.get("templates") or {}
    mobs, used, levels = {}, {}, {}
    zone = None
    for mid, sp in spawns.items():
        sp = sp or {}
        name = sp.get("template")
        tpl = templates.get(name)
        # A spawn without a position only reserves its id for scripts (InsertMobs).
        if tpl is None or not any(k in sp for k in ("at", "region", "path", "circuit")):
            continue
        tag = tpl.get("content")
        if tag is not None and str(tag).lower() not in content:
            continue
        mid = int(mid)
        zone = (mid >> 12) & 0xFFF
        lv = sp.get("level")
        m = {"t": name}
        if isinstance(lv, list) and len(lv) == 2:
            m["lv"] = [int(lv[0]), int(lv[1])]
            lo, hi = levels.get(name, (255, 0))
            levels[name] = (min(lo, m["lv"][0]), max(hi, m["lv"][1]))
        respawn = ((sp.get("attributes") or {}).get("spawn") or {}).get("respawn")
        if respawn is not None:
            m["r"] = int(respawn)
        mobs[mid] = m
        script = (sp.get("script") or name).lower()
        used[name] = used.get(name, False) or (folder.lower(), script) in scripted or (folder.lower(), name.lower()) in scripted
    if zone is None:
        return None, None, None
    infos = {n: template_info(n, templates[n], species, lists, levels.get(n, (1, 255)), s) for n, s in used.items()}
    return zone, mobs, infos
