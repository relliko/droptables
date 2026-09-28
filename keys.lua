--[[
* droptables - keys
* Whether a key is held right now (GetKeyState: the game window's own view of the keyboard).
--]]

local ffi = require('ffi');
pcall(ffi.cdef, [[
    int16_t GetKeyState(int32_t vkey);
]]);

local keys = {
    -- Name -> virtual-key code: shift, ctrl, alt, a-z, 0-9, f1-f12.
    VK = { shift = 0x10, ctrl = 0x11, alt = 0x12 },
};
for c = 0, 25 do
    keys.VK[string.char(97 + c)] = 0x41 + c;
end
for d = 0, 9 do
    keys.VK[tostring(d)] = 0x30 + d;
end
for f = 1, 12 do
    keys.VK['f' .. f] = 0x6F + f;
end

-- The raw read, replaced by the tests.
function keys.read(vk)
    return bit.band(ffi.C.GetKeyState(vk), 0x8000) ~= 0;
end

--[[
* True while the named key is held, and you aren't typing in the chat line.
--]]
function keys.held(name)
    local vk = keys.VK[name];
    if (vk == nil or not keys.read(vk)) then
        return false;
    end
    local open = AshitaCore:GetChatManager():IsInputOpen();
    return not (open == true or (type(open) == 'number' and open ~= 0));
end

return keys;
