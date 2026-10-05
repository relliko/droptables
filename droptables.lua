--[[
* droptables
*
* A frame for your current target: its era loot table with the drop chance at treasure hunter 0
* to 4 (your own TH highlighted), what THF can steal, what a shop pays for each drop, and how many
* of that mob you and your party have killed this session and in total, with the drops you
* actually got from those kills.
*
* The loot data is PhoenixXI's own (data/loot, from tools/gen_loot.py): its era drop lists and
* the server's drop rolls and treasure hunter table. Your TH is worked out from your job, level
* and equipment the way the server does it; /dt th sets it by hand.
*
* The frame can stay up (/dt show always), fade out a few seconds after you target a mob
* (/dt show fade), or only show while you hold a key (/dt show hold, /dt key). The - at the end of
* its first line minimizes it to an icon in the tray at the bottom right (tray.lua); click that to
* bring it back.
*
* Its last line is a seal timer: how long since a seal last came into your pool, how many kills
* since, and whether one can drop yet (Phoenix allows a party one every 5 minutes); /dt seals.
*
* Nothing is ever sent to the server: droptables only reads client memory and incoming packets.
--]]

addon.name    = 'droptables';
addon.author  = 'Relli';
addon.version = '0.3.1';
addon.desc    = 'Era loot table, drop rates by treasure hunter level, and kill counts for your target.';
addon.link    = 'https://github.com/relliko/droptables';

require('common');
local chat     = require('chat');
local imgui    = require('imgui');
local settings = require('settings');
local loot     = require('loot');
local kills    = require('kills');
local keys     = require('keys');
local tray     = require('tray');

local defaults = T{
    visible  = true,
    x = 520, y = 120,  -- where the frame sits
    th       = 'auto', -- your treasure hunter level: 'auto', or 0-8
    show     = 'always', -- 'always', 'fade' (after `fade` seconds on a target) or 'hold' (while `key` is held)
    fade     = 6,
    key      = 'shift',  -- keys.VK name
    lifetime = T{ },   -- kills and drops (kills.lua)
    minimized = false, -- shown as an icon at the bottom right (tray.lua) instead
    seals    = true,   -- the seal timer line
    seal     = T{ at = 0, item = 0, mob = '', zone = 0, kills = 0, n = 0 },  -- the last seal (kills.lua)
};

local dt = {
    settings  = nil,
    moved     = false, -- the frame was dragged and its spot should be saved
    reset     = false, -- put the frame back at its default spot next frame
    last_save = 0,
    shown_id  = nil,   -- the mob the frame is showing, and when it last started (or was kept) showing
    shown_at  = 0,
    hovered   = false, -- the mouse was over the frame last frame
    minimize  = false, -- its - was clicked
};

-- The minimized frame's icon: a treasure chest.
local ICON = {
    tip = 'droptables: click to open',
    panel = 0xEB1F1A17, edge = 0xC8595E5E, hot_panel = 0xEB2A2C2C, hot_edge = 0xC840B4E8,
    glyph = function (dl, x, y, w, h)
        local cx, hw = x + w / 2, h * 0.42;
        dl:AddRectFilled({ cx - hw, y + h * 0.2 }, { cx + hw, y + h * 0.42 }, 0xFF60C8F0);
        dl:AddRectFilled({ cx - hw, y + h * 0.46 }, { cx + hw, y + h * 0.8 }, 0xFF40A0D8);
        dl:AddRectFilled({ cx - h * 0.07, y + h * 0.36 }, { cx + h * 0.07, y + h * 0.56 }, 0xFF1F1A17);
    end,
};

local SAVE_EVERY = 30;
local FADE_OUT   = 1;  -- seconds the frame takes to fade away

local function msg(text)
    print(chat.header(addon.name):append(chat.message(text)));
end

local function err(text)
    print(chat.header(addon.name):append(chat.error(text)));
end

local function save()
    settings.save();
    kills.dirty, dt.last_save = false, kills.now();
end

--[[
* 1234567 -> '1,234,567'.
--]]
local function gil(n)
    local s = tostring(math.floor(n)):reverse():gsub('(%d%d%d)', '%1,'):reverse();
    return (s:gsub('^,', ''));
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

local function item_name(id)
    local res = AshitaCore:GetResourceManager():GetItemById(id);
    local name = res ~= nil and res.Name ~= nil and res.Name[1] or '';
    return name ~= '' and name or ('Item %d'):fmt(id);
end

--[[
* Your treasure hunter level, and a note on where it came from.
--]]
local function your_th()
    local s = dt.settings;
    if (type(s.th) == 'number') then
        return s.th, 'set with /dt th';
    end
    local th, trait, gear = loot.your_th();
    return th, ('trait %d + gear %d'):fmt(trait, gear);
end

--[[
* The current target, when it's a mob: its index, server id and name.
--]]
local function target_mob()
    local mm = AshitaCore:GetMemoryManager();
    local tgt, ent = mm:GetTarget(), mm:GetEntity();
    local index = tgt:GetTargetIndex(tgt:GetIsSubTargetActive());
    if (index == nil or index == 0 or index >= 0x400 or bit.band(ent:GetSpawnFlags(index), 0x10) == 0) then
        return nil;
    end
    local id = ent:GetServerId(index);
    if (id == 0) then
        return nil;
    end
    return index, id, ent:GetName(index) or '';
end

local WHITE, GOLD, DIM, RED = { 0.95, 0.94, 0.91, 1 }, { 1.0, 0.82, 0.35, 1 }, { 0.67, 0.66, 0.63, 1 }, { 0.93, 0.45, 0.42, 1 };
local GREEN = { 0.45, 0.82, 0.49, 1 };
local YOU_BG = 0x33 * 0x1000000 + 0x59 * 0x10000 + 0xD1 * 0x100 + 0xFF; -- gold wash behind your TH column (0xAABBGGRR)

local function cell(text, color)
    imgui.TableNextColumn();
    imgui.TextColored(color or WHITE, text);
end

--[[
* One table row: the item, its chance at each shown TH, what you've seen (when the Seen column is
* shown), and its NPC price.
--]]
local function item_row(label, id, chances, you_col, seen, price, color)
    imgui.TableNextRow();
    cell(label, color);
    for c, p in ipairs(chances) do
        cell(pct(p), c == you_col and GOLD or nil);
        if (c == you_col) then
            imgui.TableSetBgColor(ImGuiTableBgTarget_CellBg, YOU_BG);
        end
    end
    if (seen.column) then
        local s, l = seen.session[id] or 0, seen.lifetime[tostring(id)] or 0;
        if (id ~= 0 and (seen.kills > 0 or l > 0)) then
            cell(seen.kills > 0 and ('%d/%d (%s)'):fmt(l, seen.kills, pct(l / seen.kills)) or tostring(l), DIM);
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip(('This session: %d in %d kills\nLifetime: %d in %d kills'):fmt(s, seen.session_kills, l, seen.kills));
            end
        else
            cell('', DIM);
        end
    end
    if (price == false) then
        cell('-', DIM);
    elseif (price ~= nil) then
        cell(gil(price), DIM);
    else
        cell('', DIM);
    end
end

--[[
* The table's header row, your TH column's label in gold (with where your TH came from on hover).
--]]
local function header_row(labels, you_col, why)
    imgui.TableNextRow(ImGuiTableRowFlags_Headers);
    for i, label in ipairs(labels) do
        imgui.TableSetColumnIndex(i - 1);
        local yours = i - 1 == you_col;
        if (yours) then
            imgui.PushStyleColor(ImGuiCol_Text, GOLD);
        end
        imgui.TableHeader(label);
        if (yours) then
            imgui.PopStyleColor(1);
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip(('Your treasure hunter (%s)'):fmt(why));
            end
        end
    end
end

-- 45 -> '45s', 252 -> '4m 12s', 7500 -> '2h 05m', 280000 -> '3d 5h'.
local function span(sec)
    sec = math.floor(sec);
    if (sec < 60) then
        return ('%ds'):fmt(sec);
    elseif (sec < 3600) then
        return ('%dm %02ds'):fmt(math.floor(sec / 60), sec % 60);
    elseif (sec < 86400) then
        return ('%dh %02dm'):fmt(math.floor(sec / 3600), math.floor(sec / 60) % 60);
    end
    return ('%dd %dh'):fmt(math.floor(sec / 86400), math.floor(sec / 3600) % 24);
end

-- What the seal timer knows, as lines (the line's tooltip, and /dt seals).
local function seal_lines()
    local seal = dt.settings.seal;
    local ago, wait, since = kills.seal_state();
    local lines = { };
    if (ago == nil) then
        lines[1] = ('No seal seen yet (%d kill%s so far).'):fmt(since, since == 1 and '' or 's');
    else
        lines[1] = ('Last seal: %s%s, %s ago; %d kill%s since.'):fmt(item_name(seal.item),
            (seal.mob or '') ~= '' and (' from %s'):fmt(seal.mob) or '', span(ago), since, since == 1 and '' or 's');
        lines[2] = wait > 0 and ('No seal can drop for your party for another %d:%02d.'):fmt(math.floor(wait / 60), wait % 60)
            or 'Seals can drop again.';
    end
    lines[#lines + 1] = ('Seals seen: %d this session, %d in all.'):fmt(kills.seals_session, seal.n or 0);
    lines[#lines + 1] = 'On Phoenix a kill has a 20% chance of a seal, but after one drops your party gets no other for 5 minutes.';
    lines[#lines + 1] = 'None from NMs, or from mobs too weak to give experience. Under level 50 they give Beastmen\'s Seals; from 50, Beastmen\'s or Kindred\'s.';
    return lines;
end

--[[
* The seal timer line: since the last seal, the kills since, and whether one can drop yet.
--]]
local function seal_line(nm)
    local ago, wait, since = kills.seal_state();
    local hovered = false;
    if (ago == nil) then
        imgui.TextColored(DIM, 'No seal seen yet');
    else
        imgui.TextColored(DIM, ('Last seal %s ago, %d kill%s since'):fmt(span(ago), since, since == 1 and '' or 's'));
    end
    hovered = imgui.IsItemHovered();
    imgui.SameLine();
    if (nm) then
        imgui.TextColored(RED, 'not from NMs');
    elseif (wait > 0) then
        imgui.TextColored(GOLD, ('none for %d:%02d'):fmt(math.floor(wait / 60), wait % 60));
    else
        imgui.TextColored(GREEN, 'can drop');
    end
    if (hovered or imgui.IsItemHovered()) then
        imgui.SetTooltip(table.concat(seal_lines(), '\n'));
    end
end

local function draw()
    local s = dt.settings;
    if (s == nil or not s.visible or loot.rules == nil) then
        return;
    end
    local index, id, name = target_mob();
    if (index == nil) then
        dt.shown_id, dt.hovered = nil, false;
        return;
    end

    -- Show mode: fade out after a while on the same target, or only while the key is held.
    local t = kills.now();
    if (id ~= dt.shown_id) then
        dt.shown_id, dt.shown_at = id, t;
    end
    local alpha = 1;
    if (s.show == 'hold') then
        if (not keys.held(s.key)) then
            dt.hovered = false;
            return;
        end
    elseif (s.show == 'fade') then
        if (dt.hovered or keys.held(s.key)) then
            dt.shown_at = t;
        end
        local left = dt.shown_at + s.fade - t;
        if (left <= -FADE_OUT) then
            dt.hovered = false;
            return;
        end
        alpha = math.min(1, 1 + left / FADE_OUT);
    end

    local mob, zone, tpl, z = loot.mob(id);
    local you, why = your_th();
    local cols = loot.columns(you);
    local you_col = you >= 4 and 5 or you + 1;

    imgui.SetNextWindowPos({ s.x, s.y }, dt.reset and ImGuiCond_Always or ImGuiCond_FirstUseEver);
    dt.reset = false;
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.09, 0.10, 0.12, 0.92 });
    imgui.PushStyleColor(ImGuiCol_Border, { 0.37, 0.37, 0.35, 0.8 });
    imgui.PushStyleVar(ImGuiStyleVar_Alpha, alpha);
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 6);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 8, 6 });
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 6, 2 });
    imgui.PushStyleVar(ImGuiStyleVar_CellPadding, { 4, 1 });
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_NoScrollbar);
    if (imgui.Begin('droptables', { true }, flags)) then
        -- One line: name, level range, NM, kills.
        local sk, lk = kills.get(kills.zone(), name);
        local session_kills, lifetime_kills = sk and sk.n or 0, lk and lk.n or 0;
        imgui.TextColored(WHITE, name);
        if (mob ~= nil and mob.lv ~= nil) then
            imgui.SameLine();
            imgui.TextColored(DIM, mob.lv[1] == mob.lv[2] and ('Lv %d'):fmt(mob.lv[1]) or ('Lv %d-%d'):fmt(mob.lv[1], mob.lv[2]));
        end
        if (tpl ~= nil and tpl.nm) then
            imgui.SameLine();
            imgui.TextColored(RED, 'NM');
        end
        imgui.SameLine();
        imgui.TextColored(DIM, ('%d kills (%d total)'):fmt(session_kills, lifetime_kills));

        -- The - that minimizes the frame, at the right end of this line.
        local fs = imgui.GetFontSize();
        imgui.SameLine();
        imgui.SetCursorPosX(math.max(imgui.GetCursorPosX(), imgui.GetWindowWidth() - 8 - fs));
        local bx, by = imgui.GetCursorScreenPos();
        if (imgui.InvisibleButton('##dt_minimize', { fs, fs })) then
            dt.minimize = true;
        end
        local hot = imgui.IsItemHovered();
        local dl = imgui.GetWindowDrawList();
        if (hot) then
            dl:AddRectFilled({ bx, by }, { bx + fs, by + fs }, math.floor(0x50 * alpha) * 0x1000000 + 0xFFFFFF, 3);
            imgui.SetTooltip('Minimize to an icon at the bottom right (/dt min)');
        end
        local e, cy = fs * 0.5 * 0.7071 - 1, by + fs / 2;
        dl:AddLine({ bx + fs / 2 - e, cy }, { bx + fs / 2 + e, cy }, math.floor((hot and 0xFF or 0xB0) * alpha) * 0x1000000 + 0xFFFFFF, 1.5);

        if (tpl == nil) then
            imgui.TextColored(DIM, 'No era loot data');
        else
            local seen = { session = sk and sk.d or { }, lifetime = lk and lk.d or { }, session_kills = session_kills, kills = lifetime_kills };
            seen.column = lifetime_kills > 0 or next(seen.lifetime) ~= nil;
            local listed = { };
            local labels = { 'Item' };
            for _, th in ipairs(cols) do labels[#labels + 1] = ('TH%d'):fmt(th); end
            if (seen.column) then labels[#labels + 1] = 'Seen'; end
            labels[#labels + 1] = 'NPC';
            local tflags = bit.bor(ImGuiTableFlags_SizingFixedFit, ImGuiTableFlags_RowBg, ImGuiTableFlags_BordersInnerH, ImGuiTableFlags_NoHostExtendX);
            if (#tpl.drops > 0 and imgui.BeginTable('droptables_loot', #labels, tflags)) then
                for _, label in ipairs(labels) do
                    imgui.TableSetupColumn(label, ImGuiTableColumnFlags_WidthFixed, 0);
                end
                header_row(labels, you_col, why);
                for _, row in ipairs(loot.rows(tpl)) do
                    local chances = { };
                    for c, th in ipairs(cols) do chances[c] = loot.p(row, th); end
                    if (row.group) then
                        imgui.TableNextRow();
                        cell('One of these:', DIM);
                        for c, p in ipairs(chances) do
                            cell(pct(p), DIM);
                            if (c == you_col) then imgui.TableSetBgColor(ImGuiTableBgTarget_CellBg, YOU_BG); end
                        end
                        for _ = #chances + 2, #labels do cell('', DIM); end
                        for _, m in ipairs(row.members) do
                            local mc = { };
                            for c, th in ipairs(cols) do mc[c] = loot.p(row, th, m); end
                            if (m.id == 0) then
                                item_row('  (nothing)', 0, mc, you_col, seen, nil, DIM);
                            else
                                listed[m.id] = true;
                                item_row('  ' .. item_name(m.id), m.id, mc, you_col, seen, z.prices[m.id], nil);
                            end
                        end
                    else
                        listed[row.id] = true;
                        local label = item_name(row.id);
                        if (#row.rolls > 1) then
                            label = ('%s (%d rolls)'):fmt(label, #row.rolls);
                        end
                        item_row(label, row.id, chances, you_col, seen, z.prices[row.id], nil);
                    end
                end
                imgui.EndTable();
            elseif (#tpl.drops == 0) then
                imgui.TextColored(DIM, 'Drops nothing from its loot table');
            end

            if (#tpl.steal > 0) then
                local parts = { };
                for _, i in ipairs(tpl.steal) do parts[#parts + 1] = item_name(i); end
                imgui.TextColored(DIM, 'Steal: ' .. table.concat(parts, ', '));
            end
            if (tpl.script) then
                imgui.TextColored(DIM, 'Plus loot from a script');
            end
            -- Items you got from it that aren't in its table (seals, crystals, ...).
            local extra = { };
            for key, n in pairs(seen.lifetime) do
                local i = tonumber(key);
                if (i ~= nil and not listed[i]) then
                    extra[#extra + 1] = ('%s x%d'):fmt(item_name(i), n);
                end
            end
            if (#extra > 0) then
                table.sort(extra);
                imgui.TextColored(DIM, 'Also seen: ' .. table.concat(extra, ', '));
            end
        end
        if (s.seals ~= false) then
            seal_line(tpl ~= nil and tpl.nm);
        end

        local x, y = imgui.GetWindowPos();
        if (math.abs(x - s.x) > 0.5 or math.abs(y - s.y) > 0.5) then
            s.x, s.y, dt.moved = x, y, true;
        end
        dt.hovered = imgui.IsWindowHovered();
    end
    imgui.End();
    imgui.PopStyleVar(5);
    imgui.PopStyleColor(2);
end

local function help()
    msg('/droptables (or /dt) on|off   show the target frame');
    msg('/dt min   minimize the frame to an icon at the bottom right (so does its -); click the icon, or /dt on, to bring it back');
    msg('/dt th auto|0-8   your treasure hunter level (auto works it out from job, level and gear)');
    msg('/dt show always|fade|hold   keep the frame up (always), fade it out after you target a mob, or show it only while you hold a key');
    msg('/dt fade [seconds]   fade it out that long after you target a mob (6 s to start with)');
    msg('/dt key <key>   the key for hold (shift to start with; ctrl, alt, a-z, 0-9, f1-f12)');
    msg('/dt kills   kills in this zone, this session and lifetime');
    msg('/dt seals [on|off]   the seal timer: since the last seal, kills since, and whether one can drop yet (on|off: its line in the frame)');
    msg('/dt reset session   clear this session\'s counts; /dt reset moves the frame back');
    msg('/dt debug   what the frame knows about your target');
    msg('Your treasure hunter column has the gold header.');
end

local function describe_show()
    local s = dt.settings;
    if (s.show == 'hold') then
        return ('Target frame: shown while you hold %s.'):fmt(s.key);
    elseif (s.show == 'fade') then
        return ('Target frame: shown for %g s when you target a mob, then fades (hold %s or hover it to keep it up).'):fmt(s.fade, s.key);
    end
    return 'Target frame: always shown while you target a mob.';
end

local function print_kills()
    local zone = kills.zone();
    local rows = { };
    local l = kills.lifetime[tostring(zone)] or { };
    local s = kills.session[zone] or { };
    for name, r in pairs(l) do
        rows[#rows + 1] = { name, s[name] and s[name].n or 0, r.n };
    end
    table.sort(rows, function (a, b) return a[3] > b[3]; end);
    if (#rows == 0) then
        msg('No kills counted in this zone yet.');
        return;
    end
    for _, r in ipairs(rows) do
        msg(('%s: %d this session, %d lifetime'):fmt(r[1], r[2], r[3]));
    end
end

local function print_debug()
    local index, id, name = target_mob();
    if (index == nil) then
        msg('No mob targeted.');
        return;
    end
    local mob, zone, tpl = loot.mob(id);
    local th, why = your_th();
    msg(('%s: index %d, id %d, zone %d, template %s (%s), your TH %d (%s)'):fmt(name, index, id, zone,
        mob and mob.t or 'none', loot.zone(zone) and ('data/loot/%d.lua'):fmt(zone) or 'no data file', th, why));
    if (tpl ~= nil) then
        msg(('%d drop rolls, %d steal%s'):fmt(#tpl.drops, #tpl.steal, tpl.script and ', scripted loot' or ''));
    end
end

ashita.events.register('load', 'droptables_load', function ()
    dt.settings = settings.load(defaults);
    kills.lifetime = dt.settings.lifetime;
    kills.seal = dt.settings.seal;
    kills.reset_session();
    kills.namer = function (mid)
        local mob = loot.mob(mid);
        return mob and (mob.t:gsub('_', ' ')) or nil;
    end
    dt.last_save = kills.now();
    tray.init('droptables');
    if (not loot.init(addon.path)) then
        err(('No loot data (%s). Run tools/gen_loot.py.'):fmt(tostring(loot.error)));
    end
end);

settings.register('settings', 'droptables_settings_update', function (s)
    if (s ~= nil) then
        dt.settings = s;
        kills.lifetime = s.lifetime;
        kills.seal = s.seal;
    end
end);

ashita.events.register('unload', 'droptables_unload', function ()
    tray.hide('droptables');
    save();
end);

ashita.events.register('packet_in', 'droptables_packet_in', function (e)
    if (e.id == 0x029 or e.id == 0x0D2) then
        kills.on_packet(e.id, e.data);
    elseif (e.id == 0x00A and kills.dirty) then
        save(); -- zoning
    end
end);

ashita.events.register('command', 'droptables_command', function (e)
    local args = e.command:args();
    if (#args == 0 or (args[1]:lower() ~= '/droptables' and args[1]:lower() ~= '/dt')) then
        return;
    end
    e.blocked = true;
    local s = dt.settings;
    local what, value = (args[2] or ''):lower(), (args[3] or ''):lower();
    if (what == 'on' or what == 'off') then
        s.visible, s.minimized = what == 'on', false;
        save();
        msg(('Target frame %s.'):fmt(s.visible and 'on' or 'off'));
    elseif (what == 'min') then
        s.visible, s.minimized = true, true;
        save();
        msg('Target frame minimized to an icon at the bottom right; click it, or /dt on, to bring it back.');
    elseif (what == 'th') then
        local n = tonumber(value);
        if (value == 'auto') then
            s.th = 'auto';
            save();
        elseif (n ~= nil and n >= 0 and n <= 8 and n == math.floor(n)) then
            s.th = n;
            save();
        elseif (value ~= '') then
            err('Use /dt th auto or a level from 0 to 8.');
            return;
        end
        local th, why = your_th();
        msg(('Treasure hunter %d (%s).'):fmt(th, why));
    elseif (what == 'show') then
        if (value == 'always' or value == 'fade' or value == 'hold') then
            s.show = value;
            save();
        elseif (value ~= '') then
            err('Use /dt show always, fade or hold.');
            return;
        end
        msg(describe_show());
    elseif (what == 'fade') then
        -- Turns fading on, with a new delay when one is given ('3' or '3s').
        local n = tonumber((value:gsub('s$', '')));
        if (value ~= '' and (n == nil or n < 1 or n > 60)) then
            err('Use /dt fade and a number of seconds from 1 to 60.');
            return;
        end
        s.show, s.fade = 'fade', n or s.fade;
        save();
        msg(describe_show());
    elseif (what == 'key') then
        if (keys.VK[value] ~= nil) then
            s.key = value;
            save();
        elseif (value ~= '') then
            err('Keys: shift, ctrl, alt, a-z, 0-9 or f1-f12.');
            return;
        end
        msg(describe_show());
    elseif (what == 'kills') then
        print_kills();
    elseif (what == 'seals' or what == 'seal') then
        if (value == 'on' or value == 'off') then
            s.seals = value == 'on';
            save();
            msg(('Seal timer line %s.'):fmt(s.seals and 'on' or 'off'));
        elseif (value ~= '') then
            err('Use /dt seals, or /dt seals on or off.');
        else
            for _, line in ipairs(seal_lines()) do
                msg(line);
            end
        end
    elseif (what == 'reset' and value == 'session') then
        kills.reset_session();
        msg('This session\'s kill and drop counts are cleared.');
    elseif (what == 'reset') then
        s.x, s.y, dt.reset = defaults.x, defaults.y, true;
        save();
        msg('Target frame moved back to where it starts.');
    elseif (what == 'debug') then
        print_debug();
    else
        help();
    end
end);

ashita.events.register('d3d_present', 'droptables_present', function ()
    local s = dt.settings;
    if (s ~= nil and s.visible and s.minimized) then
        if (tray.icon('droptables', ICON)) then
            s.minimized = false;
            save();
        end
    else
        tray.hide('droptables');
        draw();
        if (dt.minimize) then
            dt.minimize, s.minimized = false, true;
            save();
        end
    end
    -- Save a dragged spot once you let go, and new counts every so often.
    local t = kills.now();
    if ((dt.moved and not imgui.IsMouseDown(ImGuiMouseButton_Left)) or (kills.dirty and t - dt.last_save >= SAVE_EVERY)) then
        dt.moved = false;
        save();
    end
    kills.prune();
end);
