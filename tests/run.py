"""
Offline test of droptables' frame: LuaJIT (lupa) with Ashita's real libs/common.lua and a fake game
and ImGui that record what the frame draws.

    python tests/run.py
    python tests/run.py --dump <server id> ...   what the frame draws for those mobs
"""

import os
import sys

from lupa import luajit21

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.dirname(HERE)
LIBS = os.path.join(os.path.dirname(ADDON), "libs")


def fwd(p):
    return p.replace("\\", "/")


def main():
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f"ADDON_DIR = [[{ADDON}]]; package.path = [[{fwd(ADDON)}/?.lua;{fwd(HERE)}/?.lua;{fwd(LIBS)}/?.lua;]] .. package.path")
    lua.execute(open(os.path.join(HERE, "fake.lua"), encoding="utf-8").read())
    if len(sys.argv) > 2 and sys.argv[1] == "--dump":
        lua.execute("DUMP_IDS = {%s}" % ",".join(str(int(a)) for a in sys.argv[2:]))
        lua.execute(open(os.path.join(HERE, "dump.lua"), encoding="utf-8").read())
        return 0
    failures = lua.execute(open(os.path.join(HERE, "tests.lua"), encoding="utf-8").read())
    print("all passed" if failures == 0 else "%d failed" % failures)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
