--[[
* droptables' tests, run by tests/run.py. Returns the number of failures.
--]]

local failures = 0;

local function check(name, ok, detail)
    if (not ok) then
        failures = failures + 1;
        print(('FAIL %s%s'):fmt(name, detail and (': ' .. detail) or ''));
    end
end

local function has(text, part)
    return text:find(part, 1, true) ~= nil;
end

-- Load the addon as Ashita would.
dofile(ADDON_DIR .. '\\droptables.lua');
fake.handlers['load']();
local info = require('info');

-- Jelly in Korroloka Tunnel: aggros by hearing, tracks by scent, doesn't link, weak to fire.
fake.target = { index = 5, id = 17485853, name = 'Jelly' };
local f = fake.frame();
for _, part in ipairs({ 'Jelly', 'Lv 23-27', 'aggro: sound, scent', 'Sneak', 'weak: fire', 'Slime Oil (3 rolls)' }) do
    check('jelly chip line: ' .. part, has(f, part), f);
end
check('details closed at start', not has(f, 'Elements'));
check('no Invis for a mob that only hears', not has(f, 'Invis'));
check('no link tag when it does not link', not has(f, 'links'));

fake.command('/dt info');
f = fake.frame();
for _, part in ipairs({ 'Takes', '50% slash, pierce · 25% blunt, h2h', 'Elements\nfire -3\n· rest -2', 'Status\nall -2',
        'TP\nFluid Spread (AoE), Fluid Toss, Digest', 'Slime · water · charmable · 10m respawn' }) do
    check('jelly details: ' .. part, has(f, part), f);
end
check('jelly has no spells line', not has(f, 'Spells'), f);
check('jelly has no immune line', not has(f, 'Immune'), f);
check('/dt info toggles back', (function () fake.command('/dt info off'); return not has(fake.frame(), 'Elements'); end)());

-- Orcish Fodder: sight and scent, Invis, links; elements with two at 0 and water lower.
fake.target = { index = 5, id = 17186886, name = 'Orcish Fodder' };
fake.command('/dt info on');
f = fake.frame();
for _, part in ipairs({ 'aggro: sight, scent', 'Invis', 'links', 'weak: water', 'Elements\nfire 0\nice 0\nwater -3\n· rest -2',
        'Status\nbind 0\nparalyze 0\npoison -3\n· rest -2', 'Shoulder Attack, Slam Dunk, Arm Block, Battle Dance (AoE) +1 more' }) do
    check('orc: ' .. part, has(f, part), f);
end
fake.command('/dt info off');

-- Tooltips draw without errors.
fake.hover = true;
fake.command('/dt info on');
f = fake.frame();
check('chip tooltips', #fake.tips > 0);
fake.hover = false;

-- info helpers.
check('duration', info.duration(600) == '10m' and info.duration(5400) == '1h 30m' and info.duration(45) == '45s' and info.duration(90) == '1m 30s');
local t = { el = { fire = -3, ice = -2, wind = -2, earth = -2, thunder = -2, water = -2, light = -2, dark = -2 } };
check('weak element stands out', table.concat(info.weak_elements(t), ',') == 'fire');
check('no weak element when all ranks are the same', #info.weak_elements({ el = { fire = -2, ice = -2, wind = -2, earth = -2, thunder = -2, water = -2, light = -2, dark = -2 } }) == 0);
check('spells by level', table.concat(info.spells({ spells = { { 1, 1, 20 }, { 2, 21, 40 }, { 3, 30, 255 } } }, { 25, 28 }), ',') == '2');
check('defaults', info.get({ }, 'sight') == 15 and info.get({ }, 'sound') == 8 and info.get({ sight = 20 }, 'sight') == 20);
local passive = info.detection_lines({ aggro = false, link = true });
check('passive mob', passive[1]:find('Doesn\'t aggro', 1, true) ~= nil and passive[#passive]:find('Links', 1, true) ~= nil);
local ts = table.concat(info.detection_lines({ aggro = true, truesight = true, det = { 'sight', 'hearing' } }), '\n');
check('true sight lines', has(ts, 'sees through Invisible') and has(ts, 'hears through Sneak'), ts);

-- Item search: matches by name, droppers by chance at your TH, steal list.
local search = require('search');
local m = search.matches('slime');
check('search matches slime oil', #m >= 1 and m[1].id == 637, tostring(m[1] and m[1].name));
check('search needs two letters', #search.matches('s') == 0);
check('search ignores case and spaces', #search.matches('  SLIME oil ') == #search.matches('slime oil'));
local drops, steal = search.lists(637, 2);
check('slime oil has droppers', #drops > 10, tostring(#drops));
local sorted, jelly = true, nil;
for i, e in ipairs(drops) do
    if (i > 1 and e.p > drops[i - 1].p) then sorted = false; end
    if (e.zone == 173 and e.meta.n == 'Jelly' and e.meta.lv[1] == 23) then jelly = e; end
end
check('droppers highest chance first', sorted);
check('Korroloka Jelly listed by its game name', jelly ~= nil);
check('Korroloka Jelly chance is all three rolls', jelly ~= nil and math.abs(jelly.p0 - 0.311) < 0.001 and math.abs(jelly.p - 0.566) < 0.001,
    jelly and ('%f %f'):fmt(jelly.p0, jelly.p));
local _, beast_steal = search.lists(656, 0);
local fodder = false;
for _, e in ipairs(beast_steal) do
    if (e.zone == 100 and e.tpl == 'Orcish_Fodder') then fodder = true; end
end
check('beastcoin stolen from Orcish Fodder', fodder);

fake.command('/dt find slime oil');
check('/dt find opens the window', search.open[1] and search.query[1] == 'slime oil');
f = fake.frame();
for _, part in ipairs({ 'Slime Oil', 'dropped by', 'Jelly', 'Zone173', '23-27', '31.1%' }) do
    check('search window: ' .. part, has(f, part), f);
end
fake.command('/dt th 2');
f = fake.frame();
check('search window adds your TH column', has(f, '31.1%\n56.6%'), f);
fake.command('/dt th auto');
search.open[1] = false;

-- Clicking an item row in the frame opens the search for it.
fake.target = { index = 5, id = 17485853, name = 'Jelly' };
fake.click = true;
fake.frame();
fake.click = false;
check('click opens search for the item', search.open[1] and search.selected == 637, tostring(search.selected));
search.open[1] = false;

-- The magnifying glass on the name line opens and closes the search.
fake.press = '##dt_search';
fake.frame();
check('search button opens the window', search.open[1] == true);
fake.frame();
check('search button closes it again', search.open[1] == false);
fake.press = nil;

-- Axe Beak (details open): rank lines are drawn with no wrap edge set, which broke them after every letter.
fake.target = { index = 5, id = 17264693, name = 'Axe Beak' };
fake.command('/dt info on');
fake.colored_wrapping = 0;
f = fake.frame();
check('no coloured text drawn while wrapping', fake.colored_wrapping == 0, tostring(fake.colored_wrapping));
check('wrap edges are popped', fake.wrapping == 0, tostring(fake.wrapping));
check('axe beak ranks', has(f, 'Elements\nwind -3\nearth +2\nthunder +2\n· rest -2'), f);
fake.command('/dt info off');

-- Every item in the index lists without errors, and every entry has its loot template.
local index_items, missing = 0, 0;
for id in pairs(search.index.drops) do
    local d = search.lists(id, 4);
    index_items = index_items + 1;
    local n = 0;
    for i = 1, #search.index.drops[id], 2 do n = n + 1; end
    if (#d ~= n) then missing = missing + 1; end
end
check('every dropped item lists all its mobs', missing == 0, ('%d of %d items lost mobs'):fmt(missing, index_items));

-- Every mob in every zone's info draws, details open, without a Lua error.
local n, zones = 0, 0;
for zone = 0, 300 do
    local z = info.zone(zone);
    if (z ~= nil) then
        zones = zones + 1;
        local done = { };
        for id, m in pairs(z.mobs) do
            check(('zone %d mob %d has its template'):fmt(zone, id), z.templates[m.t] ~= nil);
            if (not done[m.t]) then
                done[m.t] = true;
                fake.target = { index = 5, id = id, name = m.t };
                local ok, why = pcall(fake.frame);
                check(('draw %d %s'):fmt(id, m.t), ok, tostring(why));
                n = n + 1;
            end
        end
    end
end
check('info zones', zones > 150, tostring(zones));
print(('drew %d templates in %d zones'):fmt(n, zones));

return failures;
