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

-- norns hands out metros 1..30 to scripts and reserves 31..35. metro.free_all()
-- (which script.lua calls on every script change) frees only the first 30, so
-- which range the mod takes is the whole difference between a heartbeat that
-- survives loading a script and one that does not. The stub tracks both.
metro_pool = {}
metro_init_calls = 0
for i = 1, 36 do
  metro_pool[i] = {
    id = i, time = 1, event = nil, is_running = false,
    start = function(self, t) if t then self.time = t end self.is_running = true end,
    stop = function(self) self.is_running = false end,
  }
end

metro = setmetatable({
  init = function()
    metro_init_calls = metro_init_calls + 1
    return metro_pool[1]          -- a script-range metro: the wrong one
  end,
  free_all = function()
    for i = 1, 30 do metro_pool[i]:stop(); metro_pool[i].event = nil end
  end,
}, { __index = function(_, k)
  if type(k) == "number" then return metro_pool[k] end
  return nil
end })

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

-- ── the heartbeat ───────────────────────────────────────────────────────
--
-- This is the regression guard for the first hardware bug: the heartbeat was
-- on a metro.init() metro, script.lua's cleanup calls metro.free_all(), and
-- so loading any script killed it, the mirror timed out and the panel fell
-- back to its pattern.

print("\nheartbeat")
local beating = nil
for i = 1, 36 do
  if metro_pool[i].event and metro_pool[i].is_running then beating = i end
end
T.ok(beating ~= nil, "a metro is driving the heartbeat")
T.ok(beating ~= nil and beating > 30,
     "and it is a RESERVED one (31-35), not a script metro  [got " ..
     tostring(beating) .. "]")
T.eq(metro_init_calls, 0, "metro.init() is never used for it")

sent = {}
metro_pool[beating].event(1)
local beats = 0
for _, s in ipairs(sent) do if s.path == "/pf/scr/end" then beats = beats + 1 end end
T.eq(beats, 1, "each beat sends a frame-complete, which is the keepalive")

-- The bug, reproduced: a script change frees every script metro.
metro.free_all()
local still = metro_pool[beating].event ~= nil and metro_pool[beating].is_running
T.ok(still, "the heartbeat survives metro.free_all() — the script-load bug")

sent = {}
metro_pool[beating].event(1)
beats = 0
for _, s in ipairs(sent) do if s.path == "/pf/scr/end" then beats = beats + 1 end end
T.eq(beats, 1, "and still beats after a script has come and gone")

-- ── frame encoding ──────────────────────────────────────────────────────

-- Decode a payload the way the panel does, so the test asserts on pixels
-- rather than on the alphabet.
local ALPHABET =
  "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+-"
local symval = {}
for i = 1, #ALPHABET do symval[ALPHABET:sub(i, i)] = i - 1 end

local function decode(payload)
  local px = {}
  for i = 1, #payload do
    local v = symval[payload:sub(i, i)]
    px[#px + 1] = math.floor(v / 8)
    px[#px + 1] = v % 8
  end
  return px
end

print("\nframe encoding")
sent = {}
clock_now = 100
screen.update_default()   -- the wrapper installed by the mod

local frames, ends = {}, 0
for _, s in ipairs(sent) do
  if s.path == "/pf/scr" then table.insert(frames, s)
  elseif s.path == "/pf/scr/end" then ends = ends + 1 end
end
T.eq(#frames, 4, "an all-black first frame sends all 4 chunks")
T.eq(ends, 1, "and exactly one frame-complete marker, after them")
T.eq(sent[#sent].path, "/pf/scr/end", "the marker is last, so the panel shows a whole frame")
T.eq(frames[1].port, 9002, "frames go to the screencast port")
T.eq(frames[1].args[2], 4, "nchunks is 4")
T.eq(#frames[1].args[3], 1024, "each chunk is 1024 characters = 2048 pixels")
T.eq(frames[1].args[1], 0, "chunk indices start at 0")
T.eq(frames[4].args[1], 3, "last chunk index is 3")
T.eq(decode(frames[1].args[3])[1], 0, "black decodes to level 0")

-- an unchanged screen should send no chunks until the full refresh falls due
sent = {}
clock_now = 100.2
screen.update_default()
local n = 0
for _, s in ipairs(sent) do if s.path == "/pf/scr" then n = n + 1 end end
T.eq(n, 0, "an unchanged screen sends no chunks")
T.eq(sent[#sent].path, "/pf/scr/end", "but still marks the frame, so the mirror stays up")

-- 16 norns levels are quantised to 8 on the wire
screen_buf = string.char(15) .. string.char(0) .. string.rep(string.char(0), 128 * 64 - 2)
sent = {}
clock_now = 100.4
screen.update_default()
local changed = {}
for _, s in ipairs(sent) do
  if s.path == "/pf/scr" then table.insert(changed, s) end
end
T.eq(#changed, 1, "one changed pixel sends exactly one chunk")
T.eq(changed[1].args[1], 0, "the chunk that moved is chunk 0")
local px = decode(changed[1].args[3])
T.eq(px[1], 7, "norns level 15 becomes wire level 7")
T.eq(px[2], 0, "and its neighbour in the same character stays 0")

-- a pixel in the last row belongs to the last chunk
screen_buf = string.rep(string.char(0), 128 * 64 - 1) .. string.char(8)
sent = {}
clock_now = 100.6
screen.update_default()
changed = {}
for _, s in ipairs(sent) do
  if s.path == "/pf/scr" then table.insert(changed, s) end
end
T.eq(#changed, 2, "reverting one chunk and changing another sends two")
T.eq(changed[#changed].args[1], 3, "the last pixel lands in the last chunk")
px = decode(changed[#changed].args[3])
T.eq(px[#px], 4, "norns level 8 becomes wire level 4")

-- full refresh heals a panel that missed packets
sent = {}
clock_now = 103.0
screen.update_default()
n = 0
for _, s in ipairs(sent) do if s.path == "/pf/scr" then n = n + 1 end end
T.eq(n, 4, "the periodic full refresh re-sends every chunk")

-- fps throttle
sent = {}
clock_now = 103.001
screen_buf = string.rep(string.char(3), 128 * 64)
screen.update_default()
n = 0
for _, s in ipairs(sent) do if s.path == "/pf/scr" then n = n + 1 end end
T.eq(n, 0, "a frame arriving inside the fps period is dropped")

-- the test card: a diagonal that crosses every row exactly once
print("\ntest card")
sent = {}
pf.send_test_card()
local card = {}
for _, s in ipairs(sent) do
  if s.path == "/pf/scr" then card[s.args[1]] = decode(s.args[3]) end
end
T.eq(#sent, 5, "the test card is 4 chunks and a frame-complete")
local diag_ok, band_ok = true, true
for y = 0, 63 do
  local c = math.floor(y / 16)
  local within = (y % 16) * 128
  local row = card[c]
  if not row then diag_ok = false break end
  if row[within + ((y * 2) % 128) + 1] ~= 7 then diag_ok = false end
  -- x=1, not x=0: at y=0 the diagonal sits on x=0 and would mask the band.
  if y % 16 == 0 and row[within + 2] ~= 1 then band_ok = false end
end
T.ok(diag_ok, "every row of the test card carries its diagonal pixel")
T.ok(band_ok, "and each chunk boundary is marked")

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
