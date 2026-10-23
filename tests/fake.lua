--[[
* A fake game for the tests: ashita.events, AshitaCore (target, entities, player, resources), and an
* ImGui that records the text it's asked to draw. fake.target sets what you have targeted.
--]]

fake = {
    handlers = { },  -- [event name] = function
    drawn    = { },  -- text drawn this frame, in order
    tips     = { },  -- tooltips set this frame
    hover    = false, -- what IsItemHovered answers
    click    = false, -- what IsItemClicked answers
    press    = nil,   -- the id of the InvisibleButton that reports a click
    wrapping = 0,     -- PushTextWrapPos depth
    colored_wrapping = 0, -- TextColored calls made while a wrap edge was set
    item_names = { [637] = 'Slime Oil', [656] = 'Beastcoin', [16656] = 'Orcish Axe' }, -- others are 'Item<id>'
    target   = { index = 5, id = 0, name = '' },
};

addon = { path = ADDON_DIR };

ashita = {
    events = { register = function (name, _, fn) fake.handlers[name] = fn; end },
};

local function obj(methods)
    return setmetatable(methods, { __index = function () return function () return 0; end; end });
end

local entity = obj({
    GetSpawnFlags = function () return 0x10; end,
    GetServerId = function (_, i) return i == fake.target.index and fake.target.id or 0; end,
    GetName = function () return fake.target.name; end,
});
local memory = obj({
    GetTarget = function () return obj({ GetTargetIndex = function () return fake.target.index; end, GetIsSubTargetActive = function () return 0; end }); end,
    GetEntity = function () return entity; end,
    GetPlayer = function () return obj({ GetMainJob = function () return 1; end, GetSubJob = function () return 2; end }); end,
    GetInventory = function () return obj({ GetEquippedItem = function () return nil; end }); end,
    GetParty = function () return obj({ }); end,
});
local resources = obj({
    GetItemById = function (_, id) return { Name = { fake.item_names[id] or ('Item' .. id) } }; end,
    GetString = function (_, table, id) return table == 'zones.names' and ('Zone' .. id) or ''; end,
    GetSpellById = function (_, id) return { Name = { 'Spell' .. id } }; end,
});
AshitaCore = obj({
    GetMemoryManager = function () return memory; end,
    GetResourceManager = function () return resources; end,
    GetChatManager = function () return obj({ IsInputOpen = function () return false; end }); end,
    GetPluginManager = function () return obj({ }); end,
});

-- ImGui constants are all 0 here.
setmetatable(_G, { __index = function (_, k) if (type(k) == 'string' and k:match('^ImGui')) then return 0; end end });

local function record(text)
    fake.drawn[#fake.drawn + 1] = tostring(text);
end
local drawlist = obj({ });
local imgui = obj({
    Begin = function () return true; end,
    BeginTable = function () return true; end,
    Text = function (t) record(t); end,
    TextColored = function (_, t)
        record(t);
        if (fake.wrapping > 0) then fake.colored_wrapping = fake.colored_wrapping + 1; end
    end,
    TextWrapped = function (t) record(t); end,
    SetTooltip = function (t) fake.tips[#fake.tips + 1] = t; end,
    IsItemHovered = function () return fake.hover; end,
    IsItemClicked = function () return fake.click; end,
    PushTextWrapPos = function () fake.wrapping = fake.wrapping + 1; end,
    PopTextWrapPos = function () fake.wrapping = fake.wrapping - 1; end,
    InputText = function () return false; end,
    Selectable = function (t) record(t); return false; end,
    BeginChild = function () return true; end,
    IsWindowHovered = function () return false; end,
    InvisibleButton = function (id) return id == fake.press; end,
    IsMouseDown = function () return false; end,
    GetCursorScreenPos = function () return 100, 100; end,
    GetCursorPosX = function () return 8; end,
    GetWindowPos = function () return fake.settings_xy(); end,
    GetWindowWidth = function () return 300; end,
    GetFontSize = function () return 13; end,
    CalcTextSize = function (t) return #t * 7, 13; end,
    GetWindowDrawList = function () return drawlist; end,
});
package.preload['imgui'] = function () return imgui; end

package.preload['chat'] = function ()
    local s = setmetatable({ }, { __index = { append = function (self, t) return self; end } });
    return { header = function () return s; end, message = function (t) return t; end, error = function (t) return t; end };
end

local saved = nil;
package.preload['settings'] = function ()
    return {
        load = function (d) saved = d; return d; end,
        save = function () end,
        register = function () end,
    };
end
fake.settings_xy = function () return saved and saved.x or 0, saved and saved.y or 0; end

function fake.frame()
    fake.drawn, fake.tips = { }, { };
    fake.handlers['d3d_present']();
    return table.concat(fake.drawn, '\n');
end

function fake.command(text)
    local e = { command = text, blocked = false };
    fake.handlers['command'](e);
    return e.blocked;
end
