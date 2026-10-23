-- Prints what the frame draws, details open, for the server ids given in DUMP_IDS (tests/run.py --dump).
dofile(ADDON_DIR .. '/droptables.lua');
fake.handlers['load']();
fake.command('/dt info on');
for _, id in ipairs(DUMP_IDS) do
    fake.target = { index = 5, id = id, name = 'mob ' .. id };
    io.write(fake.frame(), '\n----\n');
end
