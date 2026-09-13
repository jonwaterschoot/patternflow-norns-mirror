#!/usr/bin/env python3
"""Run the offline Lua tests for the norns mod.

norns itself isn't needed: tools/test_mod.lua stubs the handful of globals
the mod touches and drives it directly. Requires `pip install lupa`.

    python tools/run_lua_tests.py
"""
import os
import sys

try:
    import lupa
except ImportError:
    sys.exit("lupa is not installed:  pip install lupa")

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
try:
    lua.execute('dofile("tools/test_mod.lua")')
except lupa.LuaError as e:
    msg = str(e)
    # os.exit() inside the script surfaces as a LuaError; treat a clean exit
    # as success and anything else as a failure worth printing.
    if "exit" not in msg.lower():
        print(msg)
        sys.exit(1)
    sys.exit(0 if "exit(0)" in msg or msg.strip().endswith("0") else 1)
