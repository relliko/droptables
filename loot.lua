--[[
* droptables - loot
* The era loot data (data/loot/<zone>.lua and data/rules.lua, from tools/gen_loot.py), the
* server's drop chance per treasure hunter level, and your own treasure hunter level.
--]]

require('common');

local loot = {
    rules  = nil,    -- data/rules.lua
    error  = nil,    -- why the data didn't load
    zones  = { },    -- [zone id] = zone data, or false when there is none
    builds = 0,      -- rows built (they're cached; the tests count this)
    cache  = setmetatable({ }, { __mode = 'k' }), -- [template] = { th = , rows = }
};

local THF = 6;

--[[
* The TH levels the table shows: 0 to 4, with the last one replaced by yours when it's higher.
--]]
function loot.columns(you)
    return { 0, 1, 2, 3, math.max(4, you or 0) };
end

local function load(path)
    local f, why = loadfile(path);
    if (f == nil) then
        return nil, why;
    end
    local ok, t = pcall(f);
    if (not ok or type(t) ~= 'table') then
        return nil, ok and (path .. ' did not return a table') or t;
    end
    return t;
end

function loot.init(dir)
    loot.dir, loot.zones = dir, { };
    loot.cache = setmetatable({ }, { __mode = 'k' });
    loot.rules, loot.error = load(dir .. '\\data\\rules.lua');
    return loot.rules ~= nil;
end

--[[
* A zone's loot data, loaded once; nil when there is none.
--]]
function loot.zone(zone)
    local z = loot.zones[zone];
    if (z == nil) then
        z = load(('%s\\data\\loot\\%d.lua'):fmt(loot.dir, zone)) or false;
        loot.zones[zone] = z;
    end
    return z or nil;
end

--[[
* xi.combat.treasureHunter.getDropRate: a rate out of 10000 at a treasure hunter level.
--]]
function loot.rate(th, rate)
    local r = loot.rules;
    th = math.max(0, math.min(14, th or 0));
    rate = math.max(0, math.min(10000, rate or 0));
    if (rate == 10000 or rate == 0) then
        return rate;
    end
    for b, floor in ipairs(r.brackets) do
        if (rate >= floor) then
            return r.table[th][b];
        end
    end
    return 0;
end

--[[
* The chance (0-1) that a roll of the given per mille rate succeeds at a treasure hunter level.
--]]
function loot.chance(th, permille)
    return math.min(1, loot.rate(th, permille * 10) * loot.rules.multiplier / 10000);
end

--[[
* Your treasure hunter level: the THF trait at your THF level (main, or sub at its level) plus
* your equipment's, capped the way the server caps it for your main job. Returns the level and
* the trait and gear parts.
--]]
function loot.your_th()
    local r = loot.rules;
    local mm = AshitaCore:GetMemoryManager();
    local p = mm:GetPlayer();
    local main = p:GetMainJob();
    local level = (main == THF and p:GetMainJobLevel()) or (p:GetSubJob() == THF and p:GetSubJobLevel()) or 0;
    local trait = 0;
    for _, t in ipairs(r.traits) do
        if (level >= t[1]) then
            trait = trait + t[2];
        end
    end
    local gear = 0;
    local inv = mm:GetInventory();
    for slot = 0, 15 do
        local e = inv:GetEquippedItem(slot);
        local index = e ~= nil and bit.band(e.Index or 0, 0xFF) or 0;
        if (index ~= 0) then
            local item = inv:GetContainerItem(bit.rshift(bit.band(e.Index, 0xFF00), 8), index);
            if (item ~= nil and item.Count ~= 0) then
                gear = gear + (r.gear[item.Id] or 0);
            end
        end
    end
    local cap = main == THF and r.cap_thf or r.cap_other;
    return math.min(trait + gear, cap), trait, gear;
end

--[[
* The table rows for a template, cached: its drops in order, with repeated rolls of an item
* merged into one row.
*   { id =, rolls = { per mille, ... } }                         -- an item rolled on its own
*   { group = true, r = per mille, members = { { id =, share = 0-1 }, ... } } -- one of several
--]]
function loot.rows(tpl)
    local c = loot.cache[tpl];
    if (c ~= nil) then
        return c;
    end
    loot.builds = loot.builds + 1;
    local rows, by_item = { }, { };
    for _, d in ipairs(tpl.drops) do
        if (d.g == nil) then
            local row = by_item[d.i];
            if (row == nil) then
                row = { id = d.i, rolls = { }, p = { } };
                by_item[d.i] = row;
                rows[#rows + 1] = row;
            end
            row.rolls[#row.rolls + 1] = d.r;
        else
            local total = 0;
            for _, m in ipairs(d.g) do
                total = total + m[2];
            end
            local row = { group = true, r = d.r, members = { }, p = { } };
            for _, m in ipairs(d.g) do
                row.members[#row.members + 1] = { id = m[1], share = total > 0 and m[2] / total or 0, p = { } };
            end
            rows[#rows + 1] = row;
        end
    end
    loot.cache[tpl] = rows;
    return rows;
end

--[[
* A row's chance at a treasure hunter level: for an item, of at least one dropping; for a group,
* of the group dropping something (pass a member for that member's chance). Remembered per level.
--]]
function loot.p(row, th, member)
    local memo = (member or row).p;
    local v = memo[th];
    if (v == nil) then
        if (member ~= nil) then
            v = loot.p(row, th) * member.share;
        elseif (row.group) then
            v = loot.chance(th, row.r);
        else
            local miss = 1;
            for _, r in ipairs(row.rolls) do
                miss = miss * (1 - loot.chance(th, r));
            end
            v = 1 - miss;
        end
        memo[th] = v;
    end
    return v;
end

--[[
* The mob with this server id: its spawn record, loot template and zone data, or nil.
--]]
function loot.mob(id)
    local zone = bit.band(bit.rshift(id, 12), 0xFFF);
    local z = loot.zone(zone);
    local m = z and z.mobs[id];
    if (m == nil) then
        return nil, zone;
    end
    return m, zone, z.templates[m.t], z;
end

return loot;
