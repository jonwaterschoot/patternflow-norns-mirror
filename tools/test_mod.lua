-- Offline test for src/norns/mod/pf-mirror/lib/mod.lua
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

-- Every destination is checked as it is sent. matron resolves a host NAME
-- again on every osc.send, blocking the Lua thread, and when mDNS fails that
-- froze norns outright. So no send may ever carry one.
sent_to_name = false
osc = {
  send = function(to, path, args)
    if not tostring(to[1]):match("^%d+%.%d+%.%d+%.%d+$") then sent_to_name = true end
    table.insert(sent, { host = to[1], port = to[2], path = path, args = args })
  end,
}

-- norns.system_cmd runs a command in a child process and answers later, by
-- callback. The stub holds the callback so a test decides when, and with what,
-- getent "answers".
cmds = {}
norns = {
  system_cmd = function(cmd, cb) table.insert(cmds, { cmd = cmd, cb = cb }) return true end,
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
  this_name = "pf-mirror",
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

local chunk, err = loadfile("src/norns/mod/pf-mirror/lib/mod.lua")
if not chunk then print("LOAD ERROR: " .. tostring(err)); os.exit(1) end
local pf = chunk()

print("startup hook")
hooks_registered["system_post_startup"]()
T.eq(#sent, 0, "nothing is sent before the panel's name has been looked up")
T.eq(#cmds, 1, "the name is looked up in a child process, not on the Lua thread")
T.eq(cmds[1] and cmds[1].cmd, "getent ahostsv4 patternflow.local", "with getent")

-- getent fails: the panel is off, or mDNS is down. This is the case that used
-- to freeze norns, every send stalling seconds on a lookup.
cmds[1].cb("")
cmds = {}
screen.update_default()
T.eq(#sent, 0, "a failed lookup sends nothing, so nothing can stall")
T.eq(pf.panel_ip(), nil, "and leaves no address")

print("\nwhere the panel is")
-- The heartbeat retries the lookup every 20 beats while the panel is silent.
local hb = metro_pool[35]
clock_now = 20                 -- more than 10 s without hearing from the panel
for stage = 1, 20 do hb.event(stage) end
T.eq(#sent, 0, "the heartbeat sends nothing without an address")
T.eq(#cmds, 1, "but it does look the name up again")
cmds[1].cb("192.168.1.50    STREAM patternflow.local\n192.168.1.50    DGRAM\n")
cmds = {}
T.eq(pf.panel_ip(), "192.168.1.50", "getent's first address becomes the panel's")
T.ok(#sent > 0, "and the handshake goes out at once")
T.eq(sent[1].path, "/patternflow/ping", "first message is the ping")
T.eq(sent[1].host, "192.168.1.50", "to the address, not the name")
T.eq(sent[1].port, 9001, "ping goes to the panel's OSC port")

-- One lookup at a time: a slow getent must not pile up child processes.
pf.config.host = "patternflow.local"
pf.items[#pf.items].fn()       -- re-ping
pf.items[#pf.items].fn()
T.eq(#cmds, 1, "a second re-ping while a lookup is running does not start another")
cmds[1].cb("")                 -- and failing it keeps the address we have
cmds = {}
T.eq(pf.panel_ip(), "192.168.1.50", "a failed re-lookup keeps the last good address")

-- The panel's own packets carry its address, which mDNS cannot get wrong.
_norns.osc.event("/patternflow/hello", { "Patternflow" }, { "192.168.1.77", "10111" })
T.eq(pf.panel_ip(), "192.168.1.77", "a packet from the panel teaches us where it is")

-- Host names go on a shell command line, so nothing else gets that far.
pf.config.host = "x; reboot"
pf.items[#pf.items].fn()
T.eq(#cmds, 0, "a host that is not a host name never reaches the shell")

-- A literal IP needs no lookup at all, and is not overridden by packets.
pf.config.host = "10.0.0.9"
pf.items[#pf.items].fn()
T.eq(#cmds, 0, "a literal IP is not looked up")
T.eq(pf.panel_ip(), "10.0.0.9", "it is the address")
_norns.osc.event("/patternflow/hello", {}, { "10.0.0.66", "10111" })
T.eq(pf.panel_ip(), "10.0.0.9", "and an IP the user typed stays theirs")
pf.config.host = "patternflow.local"
_norns.osc.event("/patternflow/hello", {}, { "192.168.1.50", "10111" })
sent = {}

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

-- Two characters per pixel triple. The band's 2048 pixels are padded to 2049,
-- so the last triple carries one pixel that is not part of the picture; it is
-- dropped here as the panel drops it.
local function decode(payload)
  local px = {}
  for i = 1, #payload, 2 do
    local v = symval[payload:sub(i, i)] * 64 + symval[payload:sub(i + 1, i + 1)]
    px[#px + 1] = math.floor(v / 256)
    px[#px + 1] = math.floor(v / 16) % 16
    px[#px + 1] = v % 16
  end
  while #px > 2048 do px[#px] = nil end
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
T.eq(#frames[1].args[3], 1366, "each chunk is 1366 characters = 2048 pixels and one pad")
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

-- all 16 norns levels survive the wire
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
T.eq(px[1], 15, "norns level 15 arrives as 15")
T.eq(px[2], 0, "and its neighbours in the same triple stay 0")

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
T.eq(px[#px], 8, "norns level 8 arrives as 8, and the pad is not a pixel")

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

-- ── test cards ──────────────────────────────────────────────────────────
--
-- These are a mode, not a one-shot. The first version sent a single frame and
-- the very next menu redraw replaced it with the real screen, so it flashed up
-- and vanished — which is no use for staring at a panel.

print("\ntest cards")

-- Rebuild the whole 64x128 image from the chunks of one frame.
local function capture_image()
  local rows = {}
  for _, s in ipairs(sent) do
    if s.path == "/pf/scr" then
      local c, px = s.args[1], decode(s.args[3])
      for i, v in ipairs(px) do
        local abs = c * 2048 + i - 1
        local y, x = math.floor(abs / 128), abs % 128
        rows[y] = rows[y] or {}
        rows[y][x] = v
      end
    end
  end
  return rows
end

local menu = pf.menu

local function sel_to(label)
  for i, it in ipairs(pf.items) do
    if it.label == label then return i end
  end
end

local function select_test(mode_name)
  -- walk the menu's `test` row to the named mode, the way a hand would
  pf.select(sel_to("test"))
  for _ = 1, #TEST_MODE_NAMES do
    if pf.test_mode_name() == mode_name then return end
    menu.enc(3, 1)
  end
  for _ = 1, #TEST_MODE_NAMES do
    if pf.test_mode_name() == mode_name then return end
    menu.enc(3, -1)
  end
end

TEST_MODE_NAMES = { "off", "diag", "rows", "line", "ramp" }

select_test("diag")
T.eq(pf.test_mode_name(), "diag", "the test row selects the diagonal card")

sent = {}
clock_now = 200
screen.update_default()
local img = capture_image()
local diag_ok, band_ok = true, true
for y = 0, 63 do
  if not img[y] then diag_ok = false break end
  if img[y][(y * 2) % 128] ~= 15 then diag_ok = false end
  -- x=1, not x=0: at y=0 the diagonal sits on x=0 and would mask the bar.
  if y % 16 == 0 and img[y][1] ~= 2 then band_ok = false end
end
T.ok(diag_ok, "every row carries its diagonal pixel")
T.ok(band_ok, "and each chunk boundary is marked")

-- It PERSISTS. This is the bug being fixed: the card used to be one frame, and
-- the very next menu redraw sent the real screen over the top of it. Turning
-- the whole screen white and redrawing must now change nothing on the wire —
-- the card has not changed, so the dirty-chunk check sends no chunks at all.
screen_buf = string.rep(string.char(15), 128 * 64)
sent = {}
clock_now = 200.2
screen.update_default()
local chunks_sent = 0
for _, s in ipairs(sent) do if s.path == "/pf/scr" then chunks_sent = chunks_sent + 1 end end
T.eq(chunks_sent, 0, "a redraw of the real screen sends nothing while a card is up")
T.eq(sent[#sent] and sent[#sent].path, "/pf/scr/end",
     "and the card is still held up by the frame-complete beat")

-- and the card, not the screen, is what a forced refresh re-sends
clock_now = 203.0
sent = {}
screen.update_default()
img = capture_image()
T.ok(img[1] ~= nil and img[1][2] == 15, "the full refresh re-sends the card, not the screen")

-- `rows`: alternate rows lit, so no two neighbours are ever equal
select_test("rows")
sent = {}
clock_now = 203.2
screen.update_default()
img = capture_image()
local alt_ok, neighbours_differ = true, true
for y = 0, 63 do
  local want = (y % 2 == 0) and 15 or 0
  for x = 0, 127 do if img[y][x] ~= want then alt_ok = false end end
end
for y = 0, 62 do
  local same = true
  for x = 0, 127 do if img[y][x] ~= img[y + 1][x] then same = false break end end
  if same then neighbours_differ = false end
end
T.ok(alt_ok, "the rows card lights every other row")
T.ok(neighbours_differ,
     "no two adjacent rows are equal — so any doubling seen on the panel is the panel")

-- `line`: one row, movable
select_test("line")
pf.select(sel_to("line y"))
sent = {}
clock_now = 203.4
screen.update_default()
img = capture_image()
local lit = {}
for y = 0, 63 do if img[y][64] == 15 then lit[#lit + 1] = y end end
T.eq(#lit, 1, "the line card lights exactly one row")
T.eq(lit[1], 5, "and starts on row 5, the reported one")

menu.enc(3, 9)            -- move it down
sent = {}
clock_now = 203.6
screen.update_default()
img = capture_image()
lit = {}
for y = 0, 63 do if img[y][64] == 15 then lit[#lit + 1] = y end end
T.eq(#lit, 1, "still exactly one row after moving it")
T.eq(lit[1], 14, "and it moved where it was told")

-- `ramp`: every level, in order, each beside its neighbours
select_test("ramp")
sent = {}
clock_now = 203.7
screen.update_default()
img = capture_image()
local rising, falling, seen = true, true, {}
for x = 0, 127 do
  local band = math.floor(x / 8)
  if img[0][x] ~= band then rising = false end
  if img[63][x] ~= 15 - band then falling = false end
  seen[img[0][x]] = true
end
local all16 = true
for lvl = 0, 15 do if not seen[lvl] then all16 = false end end
T.ok(all16, "the ramp card carries all 16 levels")
T.ok(rising, "rising left to right on the top half")
T.ok(falling, "and falling on the bottom half")

-- back to off, and the real screen returns
select_test("off")
screen_buf = string.rep(string.char(0), 128 * 64)
sent = {}
clock_now = 203.8
screen.update_default()
img = capture_image()
local all_black = true
for y = 0, 63 do for x = 0, 127 do if img[y][x] ~= 0 then all_black = false end end end
T.ok(all_black, "switching the card off returns to mirroring the real screen")

-- ── every level in every position ───────────────────────────────────────
--
-- A triple has three slots and a swapped pair of them is a picture that looks
-- plausible with every third column wrong. So walk all 16 levels through each
-- slot, at every band boundary the padding could disturb.

print("\nencoding round trip")
do
  local px = {}
  for i = 0, 128 * 64 - 1 do px[i + 1] = string.char((i * 7 + math.floor(i / 3)) % 16) end
  screen_buf = table.concat(px)
  sent = {}
  clock_now = 300
  screen.update_default()
  local got = capture_image()
  local exact = true
  for i = 0, 128 * 64 - 1 do
    local y, x = math.floor(i / 128), i % 128
    if got[y][x] ~= (i * 7 + math.floor(i / 3)) % 16 then exact = false break end
  end
  T.ok(exact, "a frame using every level in every slot comes back pixel for pixel")
  local within = true
  for _, s in ipairs(sent) do
    if s.path == "/pf/scr" and #s.args[3] ~= 1366 then within = false end
  end
  T.ok(within, "and every chunk is the same 1366 characters")
  -- address 8 + typetag 8 + two floats 8 + the string and its terminator,
  -- padded to 4: has to stay under the 1472 bytes one Wi-Fi frame carries.
  local bytes = 24 + math.floor((1366 + 4) / 4) * 4
  T.ok(bytes <= 1472, "a chunk fits one unfragmented datagram (" .. bytes .. " bytes)")
  screen_buf = string.rep(string.char(0), 128 * 64)
end

-- ── OSC routing ─────────────────────────────────────────────────────────

print("\ncontrol is off")
local dispatch = _norns.osc.event   -- the mod chained itself onto this

-- Panel knobs driving norns transferred badly on hardware and is switched off
-- (CONTROL_AVAILABLE in the mod). It has to stay off even for a norns whose
-- saved config still says control = true, which is every one that ran an
-- earlier version.
local has_control_row = false
for _, it in ipairs(pf.items) do
  if it.label == "control" then has_control_row = true end
end
T.ok(not has_control_row, "the menu does not offer control")
T.ok(#pf.items <= 6, "and every menu row fits on the screen")

pf.config.control = true
enc_calls, key_calls = {}, {}
dispatch("/patternflow/knob/1/delta", { 3 }, {})
dispatch("/patternflow/button/2/held", { 1 }, {})
T.eq(#enc_calls, 0, "a panel knob does not reach norns, even with control saved on")
T.eq(#key_calls, 0, "nor does a panel button")

print("\nOSC routing, with control turned back on")
pf.set_control_available(true)

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

T.ok(not sent_to_name, "no osc.send in this whole run was given a host name")

print(string.format("\n%d passed, %d failed", T.pass, T.fail))
os.exit(T.fail == 0 and 0 or 1)
