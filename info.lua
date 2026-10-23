--[[
* droptables - info
* What a mob is like (data/info/<zone>.lua, from tools/gen_loot.py and tools/mobinfo.py): how it
* aggros, what it resists, its TP moves and spells, and its respawn; and how to say that briefly.
--]]

require('common');

local info = {
    zones = { },    -- [zone id] = zone data, or false when there is none
};

info.ELEMENTS = { 'fire', 'ice', 'wind', 'earth', 'thunder', 'water', 'light', 'dark' };
info.ELEMENT_LABELS = { fire = 'Fire', ice = 'Ice', wind = 'Wind', earth = 'Earth', thunder = 'Thun', water = 'Water', light = 'Light', dark = 'Dark' };
info.STATUSES = { 'light_sleep', 'dark_sleep', 'bind', 'gravity', 'slow', 'paralyze', 'silence', 'blind', 'poison', 'stun' };
info.STATUS_LABELS = {
    light_sleep = 'sleep', dark_sleep = 'dark sleep', bind = 'bind', gravity = 'gravity', slow = 'slow',
    paralyze = 'paralyze', silence = 'silence', blind = 'blind', poison = 'poison', stun = 'stun',
};
info.PHYSICAL = { { 'slashing', 'Slash' }, { 'piercing', 'Pierce' }, { 'blunt', 'Blunt' }, { 'h2h', 'H2H' } };

-- Ranges the server uses when a mob's mob mods don't set its own (CMobEntity sight/sound/magic_range).
local DEFAULTS = { sight = 15, sound = 8, magic = 20, respawn = 0 };

function info.init(dir)
    info.dir, info.zones = dir, { };
end

--[[
* A zone's info data, loaded once; nil when there is none.
--]]
function info.zone(zone)
    local z = info.zones[zone];
    if (z == nil) then
        z = false;
        local f = loadfile(('%s\\data\\info\\%d.lua'):fmt(info.dir, zone));
        if (f ~= nil) then
            local ok, t = pcall(f);
            if (ok and type(t) == 'table') then
                z = t;
            end
        end
        info.zones[zone] = z;
    end
    return z or nil;
end

--[[
* The mob with this server id: its spawn record ({ t =, lv =, r = }) and its template's info, or nil.
--]]
function info.mob(id)
    local z = info.zone(bit.band(bit.rshift(id, 12), 0xFFF));
    local m = z and z.mobs[id];
    if (m == nil) then
        return nil;
    end
    return m, z.templates[m.t];
end

--[[
* A field of a template's info, with the server's default when the data leaves it out.
--]]
function info.get(t, key)
    local v = t[key];
    if (v == nil) then
        return DEFAULTS[key];
    end
    return v;
end

function info.detects(t, what)
    for _, d in ipairs(t.det or { }) do
        if (d == what) then
            return true;
        end
    end
    return false;
end

function info.immune(t, what)
    for _, d in ipairs(t.immune or { }) do
        if (d == what) then
            return true;
        end
    end
    return false;
end

--[[
* The elements a mob stands out as weak to: its lowest resistance rank, when that's below zero
* and below its others. Returns the element keys in order (none when every rank is the same).
--]]
function info.weak_elements(t)
    local el = t.el or { };
    local lo, hi = math.huge, -math.huge;
    for _, e in ipairs(info.ELEMENTS) do
        local r = el[e] or 0;
        lo, hi = math.min(lo, r), math.max(hi, r);
    end
    local out = { };
    if (lo < 0 and lo < hi) then
        for _, e in ipairs(info.ELEMENTS) do
            if ((el[e] or 0) == lo) then
                out[#out + 1] = e;
            end
        end
    end
    return out;
end

--[[
* The spells it can cast at some level in the given range: { spell id, ... }.
--]]
function info.spells(t, lv)
    local lo, hi = lv and lv[1] or 1, lv and lv[2] or 255;
    local out = { };
    for _, s in ipairs(t.spells or { }) do
        if (s[2] <= hi and s[3] >= lo) then
            out[#out + 1] = s[1];
        end
    end
    return out;
end

-- 600 -> '10m', 5400 -> '1h 30m', 45 -> '45s'.
function info.duration(sec)
    if (sec < 60) then
        return ('%ds'):fmt(sec);
    elseif (sec < 3600) then
        return sec % 60 == 0 and ('%dm'):fmt(sec / 60) or ('%dm %02ds'):fmt(math.floor(sec / 60), sec % 60);
    end
    local m = math.floor(sec / 60) % 60;
    return m == 0 and ('%dh'):fmt(math.floor(sec / 3600)) or ('%dh %02dm'):fmt(math.floor(sec / 3600), m);
end

--[[
* How it finds you, as lines of text (the expanded frame and /dt info).
--]]
function info.detection_lines(t)
    local lines = { };
    if (not t.aggro or t.noaggro) then
        lines[1] = 'Doesn\'t aggro: it only fights when attacked or linking';
    else
        if (info.detects(t, 'sight')) then
            lines[#lines + 1] = ('Sees you within %dy in front of it (%s)'):fmt(info.get(t, 'sight'),
                t.truesight and 'sees through Invisible' or 'Invisible stops it');
        end
        if (info.detects(t, 'hearing')) then
            lines[#lines + 1] = ('Hears you within %dy (%s)'):fmt(info.get(t, 'sound'), t.truesight and 'hears through Sneak' or 'Sneak stops it');
        end
        if (info.detects(t, 'magic')) then
            lines[#lines + 1] = ('Notices spells cast within %dy'):fmt(info.get(t, 'magic'));
        end
        if (info.detects(t, 'lowhp')) then
            lines[#lines + 1] = 'Notices you under 75% HP within 20y';
        end
        if (info.detects(t, 'ability')) then
            lines[#lines + 1] = 'Notices job abilities and weapon skills within 20y';
        end
        if (t.ambush) then
            lines[#lines + 1] = 'Ambushes anyone without Sneak within 3y';
        end
        if (#lines == 0) then
            lines[1] = 'Aggressive, but detects nothing on its own';
        end
        if (t.follow) then
            lines[#lines + 1] = 'Follows you for a while instead of attacking';
        end
        if (t.always) then
            lines[#lines + 1] = 'Aggros at any level, even when it checks Too Weak';
        else
            lines[#lines + 1] = 'Ignores you if it checks Too Weak, unless you rest';
        end
    end
    if (info.detects(t, 'scent')) then
        lines[#lines + 1] = 'Tracks you by scent once it\'s after you (Deodorize stops it)';
    end
    lines[#lines + 1] = t.link and 'Links with nearby mobs of its kind' or 'Doesn\'t link';
    return lines;
end

return info;
