-- Offline test for src/norns/mod/patternflow/lib/mod.lua
--
-- Stubs just enough of norns to load the mod on a desktop and exercise the
-- two things that are pure logic and easy to get wrong: the frame encoder
-- (including the dirty-chunk skipping) and the OSC routing from panel
-- addresses onto _norns.enc / _norns.key.
--
-- Run with: python tools/run_lua_tests.py

local T = { pass = 0, fail = 0 }
function T.ok(cond, name)
  if cond then T.pass = T.pass + 1; print("  ok   " .. name)
  else T.fail = T.fail + 1; print("  FAIL " .. name) end
end
local function brief(v)
  local s = tostring(v)
  if #s > 24 then s = s:sub(1, 21) .. "..." end
  return s
end
function T.eq(a, b, name)
  if a == b then T.ok(true, name)
  else T.ok(false, name .. "  (got " .. brief(a) .. ", want " .. brief(b) .. ")") end
end

-- ── norns stubs ─────────────────────────────────────────────────────────

local clock_now = 0

sent = {}            -- captured osc.send calls
enc_calls = {}
key_calls = {}

paths = { data = "/tmp/data/", code = "/tmp/code/" }

local screen_buf = string.rep(string.char(0), 128 * 64)

screen = {
  peek = function(x, y, w, h) return screen_buf end,
  update_default = function() end,
  clear = function() end, level = function() end, move = function() end,
  text = function() end, text_right = function() end, update = function() end,
}
screen.update = screen.update_default

osc = {
  send = function(to, path, args)
    table.insert(sent, { host = to[1], port = to[2], path = path, args = args })
  end,
}

_norns = {
  osc = { event = function() end },
  enc = function(n, d) table.insert(enc_calls, { n = n, d = d }) end,
  key = function(n, z) table.insert(key_calls, { n = n, z = z }) end,
  get_time = function() return math.floor(clock_now), (clock_now % 1) * 1e6 end,
}

metro = {
  init = function()
    return { time = 1, event = nil, start = function() end, stop = function() end }
  end,
}

-- module stubs resolved through require
local stub_util = {
  time = function() return clock_now end,
  clamp = function(n, lo, hi) return math.min(math.max(n, lo), hi) end,
  make_dir = function() end,
}
local stub_tab = { load = function() return nil end, save = function() end }

local hooks_registered = {}
local stub_mods = {
  this_name = "patternflow",
  hook = { register = function(which, name, fn) hooks_registered[which] = fn end },
  menu = { register = function() end, redraw = function() end, exit = function() end },
}

local real_require = require
require = function(name)
  if name == 'core/mods' then return stub_mods end
  if name == 'tabutil' then return stub_tab end
  if name == 'util' then return stub_util end
  return real_require(name)
end

-- ── load the mod ────────────────────────────────────────────────────────

local chunk, err = loadfile("src/norns/mod/patternflow/lib/mod.lua")
if not chunk then print("LOAD ERROR: " .. tostring(err)); os.exit(1) end
local pf = chunk()

print("startup hook")
hooks_registered["system_post_startup"]()
T.ok(#sent > 0, "handshake ping sent on startup")
T.eq(sent[1].path, "/patternflow/ping", "first message is the ping")
T.eq(sent[1].port, 9001, "ping goes to the panel's OSC port")

-- ── frame encoding ──────────────────────────────────────────────────────

print("\nframe encoding")
sent = {}
clock_now = 100
screen.update_default()   -- the wrapper installed by the mod

local frames = {}
for _, s in ipairs(sent) do
  if s.path == "/pf/scr" then table.insert(frames, s) end
end
T.eq(#frames, 8, "an all-black first frame sends all 8 chunks")
T.eq(frames[1].port, 9002, "frames go to the screencast port")
T.eq(frames[1].args[2], 8, "nchunks is 8")
T.eq(#frames[1].args[3], 1024, "each chunk carries 1024 pixels")
T.eq(frames[1].args[3], string.rep("0", 1024), "level 0 encodes as '0'")
T.eq(frames[1].args[1], 0, "chunk indices start at 0")
T.eq(frames[8].args[1], 7, "last chunk index is 7")

-- an unchanged screen should send nothing until the full refresh falls due
sent = {}
clock_now = 100.2
screen.update_default()
local n = 0
for _, s in ipairs(sent) do if s.path == "/pf/scr" then n = n + 1 end end
T.eq(n, 0, "an unchanged screen sends no chunks")

-- change one pixel in the top-left: only chunk 0 should move
screen_buf = string.char(15) .. string.rep(string.char(0), 128 * 64 - 1)
sent = {}
clock_now = 100.4
screen.update_default()
local changed = {}
for _, s in ipairs(sent) do
  if s.path == "/pf/scr" then table.insert(changed, s) end
end
T.eq(#changed, 1, "one changed pixel sends exactly one chunk")
T.eq(changed[1].args[1], 0, "the chunk that moved is chunk 0")
T.eq(changed[1].args[3]:sub(1, 1), "f", "level 15 encodes as 'f'")

-- a pixel in the last row belongs to chunk 7
screen_buf = string.rep(string.char(0), 128 * 64 - 1) .. string.char(8)
sent = {}
clock_now = 100.6
screen.update_default()
changed = {}
for _, s in ipairs(sent) do
  if s.path == "/pf/scr" then table.insert(changed, s) end
end
T.eq(#changed, 2, "reverting one chunk and changing another sends two")
T.eq(changed[#changed].args[1], 7, "the last pixel lands in chunk 7")
T.eq(changed[#changed].args[3]:sub(1024, 1024), "8", "level 8 encodes as '8'")

-- full refresh heals a panel that missed packets
sent = {}
clock_now = 103.0
screen.update_default()
n = 0
for _, s in ipairs(sent) do if s.path == "/pf/scr" then n = n + 1 end end
T.eq(n, 8, "the periodic full refresh re-sends every chunk")

-- fps throttle
sent = {}
clock_now = 103.001
screen_buf = string.rep(string.char(3), 128 * 64)
screen.update_default()
n = 0
for _, s in ipairs(sent) do if s.path == "/pf/scr" then n = n + 1 end end
T.eq(n, 0, "a frame arriving inside the fps period is dropped")

-- ── OSC routing ─────────────────────────────────────────────────────────

print("\nOSC routing")
local dispatch = _norns.osc.event   -- the mod chained itself onto this

enc_calls, key_calls = {}, {}
dispatch("/patternflow/knob/1/delta", { 3 }, {})
T.eq(#enc_calls, 1, "knob 1 delta reaches an encoder")
T.eq(enc_calls[1].n, 1, "panel knob 1 -> norns enc 1")
T.eq(enc_calls[1].d, 3, "delta is passed through")

dispatch("/patternflow/knob/3/delta", { -2 }, {})
T.eq(enc_calls[2].n, 3, "panel knob 3 -> norns enc 3")
T.eq(enc_calls[2].d, -2, "negative delta survives")

enc_calls = {}
dispatch("/patternflow/knob/4/delta", { 5 }, {})
T.eq(#enc_calls, 0, "panel knob 4 is left to the panel")

dispatch("/patternflow/knob/1/clicks", { 40 }, {})
T.eq(#enc_calls, 0, "absolute /clicks is ignored, only /delta drives")

dispatch("/patternflow/knob/1/delta", { 0 }, {})
T.eq(#enc_calls, 0, "a zero delta is not forwarded")

key_calls = {}
dispatch("/patternflow/button/2/held", { 1 }, {})
dispatch("/patternflow/button/2/held", { 0 }, {})
T.eq(#key_calls, 2, "held gives a down and an up")
T.eq(key_calls[1].n, 2, "panel button 2 -> norns key 2")
T.eq(key_calls[1].z, 1, "held 1 is key down")
T.eq(key_calls[2].z, 0, "held 0 is key up")

key_calls = {}
dispatch("/patternflow/button/2/press", { 1 }, {})
T.eq(#key_calls, 0, "press is ignored so keys aren't doubled")

key_calls = {}
dispatch("/patternflow/button/4/held", { 1 }, {})
T.eq(#key_calls, 0, "panel button 4 is left to the panel")

-- unrelated traffic must pass through untouched
local passed = false
_norns.osc.event = nil
local ok = pcall(dispatch, "/something/else", { 1 }, {})
T.ok(ok, "unrelated OSC addresses don't error")

print(string.format("\n%d passed, %d failed", T.pass, T.fail))
os.exit(T.fail == 0 and 0 or 1)
