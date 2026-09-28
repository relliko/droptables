--[[
* droptables - kills
* Counts the mobs you and your party kill, and the items they leave in your treasure pool, from
* incoming packets (read only: handlers never block or change a packet).
*
*   0x029 message 6 "<actor> defeats <mob>" / 20 "<mob> falls to the ground": sent to everyone
*         nearby, so a kill counts only when the actor is you, a party or alliance member or one of
*         their pets, or when the mob was claimed by one of you.
*   0x0D2 an item entering your treasure pool, with the mob that dropped it (skipping items the
*         server re-sends when you zone or join a party, and chests).
*
* Kills and drops are counted by mob name within a zone: for this session in memory, and for your
* lifetime in your character's settings (lifetime[zone][name] = { n = kills, d = { [item] = n } },
* numbers kept as string keys for the settings file).
--]]

require('common');

local kills = {
    session  = { },   -- [zone][name] = { n = kills, d = { [item id] = count } }
    lifetime = nil,   -- the settings table
    recent   = { },   -- [mob server id] = { t = time, zone =, name = } kills awaiting their drops
    pool     = { },   -- [pool slot] = 'dropper:item' last counted there
    dirty    = false, -- lifetime changed since the last save
    now      = os.clock,
    zone     = function () return AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0); end,
    namer    = nil,   -- fallback name for a mob id the client no longer knows (set by droptables.lua)
};

local DEFEATS, FALLS = 6, 20;
local REPEAT = 10;    -- seconds: another death message for the same mob in this time is the same kill
local DROPS  = 60;    -- seconds after a kill its pool items are credited to it

local function u16(d, o) local a, b = d:byte(o + 1, o + 2); return a + b * 256; end
local function u32(d, o) local a, b, c, e = d:byte(o + 1, o + 4); return a + b * 256 + c * 65536 + e * 16777216; end

--[[
* Server ids of you, your party and alliance, and their pets.
--]]
local function ours()
    local mm = AshitaCore:GetMemoryManager();
    local party, ent = mm:GetParty(), mm:GetEntity();
    local ids = { };
    for i = 0, 17 do
        if (party:GetMemberIsActive(i) ~= 0) then
            local sid = party:GetMemberServerId(i);
            if (sid ~= 0) then
                ids[sid] = true;
            end
            local idx = party:GetMemberTargetIndex(i);
            local pet = idx ~= 0 and ent:GetPetTargetIndex(idx) or 0;
            if (pet ~= 0 and ent:GetServerId(pet) ~= 0) then
                ids[ent:GetServerId(pet)] = true;
            end
        end
    end
    return ids;
end

-- The record for a mob in a zone, in session or lifetime counts, made when missing.
local function record(book, zone, name)
    local z = book[zone];
    if (z == nil) then
        z = T{ };
        book[zone] = z;
    end
    local r = z[name];
    if (r == nil) then
        r = T{ n = 0, d = T{ } };
        z[name] = r;
    end
    return r;
end

local function add(zone, name, kill, item)
    local s, l = record(kills.session, zone, name), record(kills.lifetime, tostring(zone), name);
    if (kill) then
        s.n, l.n = s.n + 1, l.n + 1;
    end
    if (item ~= nil) then
        s.d[item] = (s.d[item] or 0) + 1;
        l.d[tostring(item)] = (l.d[tostring(item)] or 0) + 1;
    end
    kills.dirty = true;
end

-- The mob's name: what the client shows for it, or the loot data's.
local function mob_name(id, index)
    local ent = AshitaCore:GetMemoryManager():GetEntity();
    if (index ~= nil and index > 0 and index < 0x400 and ent:GetServerId(index) == id) then
        local name = ent:GetName(index);
        if (name ~= nil and name ~= '') then
            return name;
        end
    end
    return kills.namer ~= nil and kills.namer(id) or nil;
end

function kills.on_packet(id, data)
    if (kills.lifetime == nil) then
        return;
    end
    local t = kills.now();
    if (id == 0x029 and #data >= 0x1A) then
        local msg = u16(data, 0x18);
        if (msg ~= DEFEATS and msg ~= FALLS) then
            return;
        end
        local actor, mob, index = u32(data, 0x04), u32(data, 0x08), u16(data, 0x16);
        if (index == 0 or index >= 0x400) then
            return;
        end
        local prev = kills.recent[mob];
        if (prev ~= nil and t - prev.t < REPEAT) then
            return;
        end
        local group = ours();
        local claim = AshitaCore:GetMemoryManager():GetEntity():GetClaimStatus(index);
        if (not ((msg == DEFEATS and group[actor]) or (claim ~= 0 and group[claim]))) then
            return;
        end
        local name = mob_name(mob, index);
        if (name == nil) then
            return;
        end
        local zone = kills.zone();
        kills.recent[mob] = { t = t, zone = zone, name = name };
        add(zone, name, true, nil);
    elseif (id == 0x0D2 and #data >= 0x17) then
        local dropper, item, slot = u32(data, 0x08), u16(data, 0x10), data:byte(0x14 + 1);
        local old, chest = data:byte(0x15 + 1), data:byte(0x16 + 1);
        if (old ~= 0 or chest ~= 0 or item == 0 or dropper == 0) then
            return;
        end
        local key, prev = ('%d:%d'):fmt(dropper, item), kills.pool[slot];
        if (prev ~= nil and prev.key == key and t - prev.t < DROPS) then
            return;
        end
        kills.pool[slot] = { key = key, t = t };
        local k = kills.recent[dropper];
        if (k ~= nil and t - k.t < DROPS) then
            add(k.zone, k.name, false, item);
            return;
        end
        local name = mob_name(dropper, u16(data, 0x12));
        if (name ~= nil) then
            add(kills.zone(), name, false, item);
        end
    end
end

--[[
* Session and lifetime records for a mob in a zone (either may be nil).
--]]
function kills.get(zone, name)
    local s = kills.session[zone];
    local l = kills.lifetime and kills.lifetime[tostring(zone)];
    return s and s[name], l and l[name];
end

function kills.reset_session()
    kills.session, kills.recent, kills.pool = { }, { }, { };
end

-- Kills older than DROPS can't get drops any more.
function kills.prune()
    local t = kills.now();
    for id, k in pairs(kills.recent) do
        if (t - k.t >= DROPS) then
            kills.recent[id] = nil;
        end
    end
end

return kills;
