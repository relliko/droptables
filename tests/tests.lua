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
for _, part in ipairs({ 'Jelly', 'Lv 23-27', 'aggro: sound, scent', 'Sneak', 'weak: fire', 'Item637 (3 rolls)' }) do
    check('jelly chip line: ' .. part, has(f, part), f);
end
check('details closed at start', not has(f, 'Elements'));
check('no Invis for a mob that only hears', not has(f, 'Invis'));
check('no link tag when it does not link', not has(f, 'links'));

fake.command('/dt info');
f = fake.frame();
for _, part in ipairs({ 'Takes', '50% slash, pierce · 25% blunt, h2h', 'Elements\nfire -3\nrest -2', 'Status\nall -2',
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
for _, part in ipairs({ 'aggro: sight, scent', 'Invis', 'links', 'weak: water', 'Elements\nfire 0\nice 0\nwater -3\nrest -2',
        'Status\nbind 0\nparalyze 0\npoison -3\nrest -2', 'Shoulder Attack, Slam Dunk, Arm Block, Battle Dance (AoE) +1 more' }) do
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
