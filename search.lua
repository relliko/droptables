--[[
* droptables - search
* The item search window (/dt find, or click an item in the frame): every mob that drops the item,
* highest chance at your treasure hunter first, and every mob it can be stolen from. The index of
* who drops what is data/items.lua (tools/items.py); the chances come from each zone's loot file.
--]]

require('common');
local imgui = require('imgui');
local loot  = require('loot');

local search = {
    open     = { false },
    query    = { '' },
    selected = nil,     -- item id
    focus    = false,   -- put the cursor in the box next frame
    index    = nil,     -- data/items.lua, loaded the first time the window opens
    error    = nil,
    names    = nil,     -- { { id =, name =, lower = }, ... } for every indexed item
    matched  = { q = nil, list = { } },
    cache    = { },     -- [item id] = { th =, drops =, steal = }
};

local WHITE, GOLD, DIM, RED = { 0.95, 0.94, 0.91, 1 }, { 1.0, 0.82, 0.35, 1 }, { 0.67, 0.66, 0.63, 1 }, { 0.93, 0.45, 0.42, 1 };
local MAX_MATCHES = 60;

function search.init(dir)
    search.dir = dir;
end

local function load_index()
    if (search.index ~= nil or search.error ~= nil) then
        return search.index;
    end
    local f, why = loadfile(search.dir .. '\\data\\items.lua');
    local ok, t = false, why;
    if (f ~= nil) then
        ok, t = pcall(f);
    end
    if (ok and type(t) == 'table') then
        search.index = t;
    else
        search.error = tostring(t);
    end
    return search.index;
end

local function item_name(id)
    local res = AshitaCore:GetResourceManager():GetItemById(id);
    local name = res ~= nil and res.Name ~= nil and res.Name[1] or '';
    return name ~= '' and name or ('Item %d'):fmt(id);
end

local zone_names = { };
local function zone_name(id)
    local n = zone_names[id];
    if (n == nil) then
        n = AshitaCore:GetResourceManager():GetString('zones.names', id) or '';
        if (n == '') then n = ('Zone %d'):fmt(id); end
        zone_names[id] = n;
    end
    return n;
end
search.zone_name = zone_name;

--[[
* Every item in the index with its name, built once.
--]]
local function all_names()
    if (search.names == nil) then
        local seen, list = { }, { };
        for _, key in ipairs({ 'drops', 'steal' }) do
            for id in pairs(search.index[key]) do
                if (not seen[id]) then
                    seen[id] = true;
                    local name = item_name(id);
                    list[#list + 1] = { id = id, name = name, lower = name:lower() };
                end
            end
        end
        table.sort(list, function (a, b) return a.lower < b.lower; end);
        search.names = list;
    end
    return search.names;
end

--[[
* The items whose name contains the query (any case), those starting with it first.
--]]
function search.matches(q)
    q = (q or ''):lower():gsub('^%s+', ''):gsub('%s+$', '');
    if (search.matched.q == q) then
        return search.matched.list;
    end
    local starts, contains = { }, { };
    if (#q >= 2 and load_index() ~= nil) then
        for _, it in ipairs(all_names()) do
            local at = it.lower:find(q, 1, true);
            if (at == 1) then
                starts[#starts + 1] = it;
            elseif (at ~= nil) then
                contains[#contains + 1] = it;
            end
        end
    end
    for _, it in ipairs(contains) do starts[#starts + 1] = it; end
    search.matched = { q = q, list = starts };
    return starts;
end

--[[
* The chance (0-1) that a mob with this loot template drops at least one of the item at a TH.
--]]
function search.chance(tpl, item, th)
    local miss = 1;
    for _, row in ipairs(loot.rows(tpl)) do
        if (row.group) then
            local p = 0;
            for _, m in ipairs(row.members) do
                if (m.id == item) then p = p + loot.p(row, th, m); end
            end
            miss = miss * (1 - p);
        elseif (row.id == item) then
            miss = miss * (1 - loot.p(row, th));
        end
    end
    return 1 - miss;
end

local function mob_entries(item, key)
    local flat = search.index[key][item] or { };
    local out = { };
    for i = 1, #flat, 2 do
        local zone, tpl = flat[i], flat[i + 1];
        local meta = (search.index.mobs[zone] or { })[tpl] or { n = tpl };
        out[#out + 1] = { zone = zone, tpl = tpl, meta = meta };
    end
    return out;
end

local function by_level(a, b)
    local la, lb = a.meta.lv and a.meta.lv[1] or 0, b.meta.lv and b.meta.lv[1] or 0;
    if (la ~= lb) then return la < lb; end
    return a.meta.n < b.meta.n;
end

--[[
* The mobs that drop the item, highest chance at this TH first ({ zone, tpl, meta, p, p0 }), and
* those it can be stolen from, lowest level first. Remembered per item and TH.
--]]
function search.lists(item, th)
    local c = search.cache[item];
    if (c ~= nil and c.th == th) then
        return c.drops, c.steal;
    end
    local drops = { };
    for _, e in ipairs(mob_entries(item, 'drops')) do
        local z = loot.zone(e.zone);
        local tpl = z and z.templates[e.tpl];
        if (tpl ~= nil) then
            e.p, e.p0 = search.chance(tpl, item, th), search.chance(tpl, item, 0);
            drops[#drops + 1] = e;
        end
    end
    table.sort(drops, function (a, b)
        if (a.p ~= b.p) then return a.p > b.p; end
        if ((a.meta.fished or false) ~= (b.meta.fished or false)) then return not a.meta.fished; end
        return by_level(a, b);
    end);
    local steal = mob_entries(item, 'steal');
    table.sort(steal, by_level);
    search.cache[item] = { th = th, drops = drops, steal = steal };
    return drops, steal;
end

--[[
* Opens the window; with an item id, showing that item (its name in the box).
--]]
function search.show(query, item)
    search.open[1] = true;
    search.query[1] = query or search.query[1];
    search.selected = item;
    search.focus = item == nil;
end

-- 0.24 -> '24%', 0.425 -> '42.5%', 0.005 -> '0.5%'.
local function pct(p)
    if (p <= 0) then
        return '-';
    elseif (p < 0.001) then
        return '<0.1%';
    end
    return (('%.1f'):fmt(p * 100):gsub('%.0$', '')) .. '%';
end

local function level_text(meta)
    local lv = meta.lv;
    if (lv == nil) then return ''; end
    return lv[1] == lv[2] and tostring(lv[1]) or ('%d-%d'):fmt(lv[1], lv[2]);
end

local function mob_cells(e)
    imgui.TableNextColumn();
    imgui.TextColored(e.meta.nm and RED or WHITE, e.meta.n);
    if (e.meta.fished and imgui.IsItemHovered()) then imgui.SetTooltip('Only hooked while fishing'); end
    if (e.meta.fished or e.meta.nm) then
        imgui.SameLine();
        imgui.TextColored(DIM, e.meta.nm and 'NM' or 'fished');
    end
    imgui.TableNextColumn();
    imgui.TextColored(DIM, zone_name(e.zone));
    imgui.TableNextColumn();
    imgui.TextColored(DIM, level_text(e.meta));
end

local ROWS_MATCHES, ROWS_DROPS, ROWS_STEAL = 5, 10, 5;

--[[
* The window. th and why: your treasure hunter and where it came from.
--]]
function search.draw(th, why, pos)
    if (not search.open[1]) then
        return;
    end
    local fs = imgui.GetFontSize();
    local row_h = fs + 4;
    imgui.SetNextWindowPos({ pos.x, pos.y }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSize({ 30 * fs, 0 }, ImGuiCond_Always);
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.09, 0.10, 0.12, 0.95 });
    imgui.PushStyleColor(ImGuiCol_Border, { 0.37, 0.37, 0.35, 0.8 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 6);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 8, 6 });
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 6, 2 });
    imgui.PushStyleVar(ImGuiStyleVar_CellPadding, { 4, 1 });
    local flags = bit.bor(ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoScrollbar);
    if (imgui.Begin('droptables: find an item###droptables_search', search.open, flags)) then
        if (search.focus) then
            imgui.SetKeyboardFocusHere();
            search.focus = false;
        end
        imgui.PushItemWidth(-1);
        if (imgui.InputText('##dt_find', search.query, 64)) then
            search.selected = nil;
        end
        imgui.PopItemWidth();

        local list = search.matches(search.query[1]);
        if (search.error ~= nil) then
            imgui.TextColored(RED, 'No item index (data/items.lua). Run tools/gen_loot.py.');
        elseif (#search.query[1]:gsub('%s', '') < 2) then
            imgui.TextColored(DIM, 'Type part of an item\'s name.');
        elseif (#list == 0) then
            imgui.TextColored(DIM, 'No mob drops an item by that name.');
        end
        if (search.selected == nil and #list == 1) then
            search.selected = list[1].id;
        end

        -- The matching items, while none is picked (or more than one matches).
        if (#list > 1) then
            local shown = math.min(#list, MAX_MATCHES);
            imgui.BeginChild('##dt_matches', { 0, math.min(shown, ROWS_MATCHES) * row_h + 2 }, 0);
            for i = 1, shown do
                local it = list[i];
                if (imgui.Selectable(('%s##dt_m%d'):fmt(it.name, it.id), it.id == search.selected)) then
                    search.selected = it.id;
                end
            end
            imgui.EndChild();
            if (#list > MAX_MATCHES) then
                imgui.TextColored(DIM, ('%d more; type more of the name'):fmt(#list - MAX_MATCHES));
            end
        end

        if (search.selected ~= nil and load_index() ~= nil) then
            local item = search.selected;
            local drops, steal = search.lists(item, th);
            imgui.Separator();
            imgui.TextColored(GOLD, item_name(item));
            imgui.SameLine();
            imgui.TextColored(DIM, ('dropped by %d, stolen from %d'):fmt(#drops, #steal));

            local tflags = bit.bor(ImGuiTableFlags_SizingFixedFit, ImGuiTableFlags_RowBg, ImGuiTableFlags_BordersInnerH, ImGuiTableFlags_ScrollY);
            if (#drops > 0) then
                local cols = th > 0 and 5 or 4;
                local h = (math.min(#drops, ROWS_DROPS) + 1) * row_h + 2;
                if (imgui.BeginTable('##dt_drops', cols, tflags, { 0, h })) then
                    imgui.TableSetupScrollFreeze(0, 1);
                    imgui.TableSetupColumn('Dropped by', ImGuiTableColumnFlags_WidthStretch, 0);
                    imgui.TableSetupColumn('Zone', ImGuiTableColumnFlags_WidthFixed, 0);
                    imgui.TableSetupColumn('Lv', ImGuiTableColumnFlags_WidthFixed, 0);
                    imgui.TableSetupColumn('TH0', ImGuiTableColumnFlags_WidthFixed, 0);
                    if (th > 0) then imgui.TableSetupColumn(('TH%d'):fmt(th), ImGuiTableColumnFlags_WidthFixed, 0); end
                    imgui.TableHeadersRow();
                    for _, e in ipairs(drops) do
                        imgui.TableNextRow();
                        mob_cells(e);
                        imgui.TableNextColumn();
                        imgui.TextColored(th > 0 and DIM or GOLD, pct(e.p0));
                        if (th > 0) then
                            imgui.TableNextColumn();
                            imgui.TextColored(GOLD, pct(e.p));
                            if (imgui.IsItemHovered()) then imgui.SetTooltip(('At your treasure hunter (%s)'):fmt(why)); end
                        end
                    end
                    imgui.EndTable();
                end
            end
            if (#steal > 0) then
                local h = (math.min(#steal, ROWS_STEAL) + 1) * row_h + 2;
                if (imgui.BeginTable('##dt_steal', 3, tflags, { 0, h })) then
                    imgui.TableSetupScrollFreeze(0, 1);
                    imgui.TableSetupColumn('Steal from', ImGuiTableColumnFlags_WidthStretch, 0);
                    imgui.TableSetupColumn('Zone', ImGuiTableColumnFlags_WidthFixed, 0);
                    imgui.TableSetupColumn('Lv', ImGuiTableColumnFlags_WidthFixed, 0);
                    imgui.TableHeadersRow();
                    for _, e in ipairs(steal) do
                        imgui.TableNextRow();
                        mob_cells(e);
                    end
                    imgui.EndTable();
                end
            end
        end
    end
    imgui.End();
    imgui.PopStyleVar(4);
    imgui.PopStyleColor(2);
end

return search;
