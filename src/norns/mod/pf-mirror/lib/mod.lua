-- pf-mirror — the norns screen on a Patternflow panel (system mod)
--
-- Unofficial: a personal project, not affiliated with or endorsed by
-- Patternflow or monome. https://github.com/jonwaterschoot/patternflow-norns-mirror
--
-- Three jobs:
--
--   mirror    the norns screen is sent to the panel's `screencast` feature.
--   handshake tells the panel where we are, so its own OSC output finds us,
--             and is how the menu knows whether a panel is there at all.
--   control   the panel's encoders and buttons drive norns as if they were
--             the physical ones. SWITCHED OFF for now — see CONTROL_AVAILABLE.
--
-- All of it is plain Lua. No native build, no norns fork.
-- The facts this is written against are in docs/01-verified-facts.md.
--
-- Install: this directory goes to ~/dust/code/pf-mirror/ on norns, then
-- SYSTEM > MODS > PF-MIRROR, turn E3 right, and restart. The README has a
-- one-line install from maiden.

local mod = require 'core/mods'
local tab = require 'tabutil'
local util = require 'util'

local this_name = mod.this_name or "pf-mirror"

-- Must match PF_VARIANT_VERSION in the firmware's overrides.h: the two halves
-- are released together, and tools/release.sh refuses to cut one where they
-- disagree.
local VERSION = "v0.5.0"

local pf = {}

-- Panel knobs and buttons driving norns. Off, and not offered in the menu.
--
-- On hardware it transferred badly: turns arrived wrong or not at all, and at
-- times norns appeared to hang or to be fighting the panel for the same input.
-- Until that is understood the mod does one thing — the mirror — and does it
-- well. The routing is kept intact below, and still tested, so turning this
-- back on is this one line.
--
-- It is a constant rather than just a new default for config.control because
-- config is saved on norns: every unit that ran an earlier version has
-- `control = true` in its config file, and that would win over any default.
local CONTROL_AVAILABLE = false

-- ─────────────────────────────────────────────────────────────────────────
-- Configuration
-- ─────────────────────────────────────────────────────────────────────────

local CONF_DIR = paths.data .. this_name .. "/"
local CONF_FILE = CONF_DIR .. "config.lua"

-- Defaults. `host` is the only one you normally have to touch: use the
-- panel's IP if mDNS doesn't resolve from norns (see README troubleshooting).
--
-- The knob/key maps leave panel channel 4 alone on purpose. Long-pressing
-- encoder 4 is how the panel itself switches patterns, and knob 4 is what
-- the screencast feature uses for mirror hue — so 4 stays the panel's own.
local config = {
  host = "patternflow.local",
  osc_port = 9001,   -- PF_OSC_LOCAL_PORT: the panel's OSC feature listens here
  scr_port = 9002,   -- PF_SCREENCAST_PORT: our feature's own socket

  control = false,   -- only consulted while CONTROL_AVAILABLE is true
  mirror = true,

  fps = 20,          -- mirror cap; the screen rarely changes faster than this

  enc_map = { 1, 2, 3, 0 },  -- panel knob N -> norns encoder (0 = leave to the panel)
  key_map = { 1, 2, 3, 0 },  -- panel button N -> norns key

  -- Which of norns's reserved metros (31-35) drives the heartbeat. Reserved
  -- ones are never handed out by metro.init() and never stopped by
  -- metro.free_all(), which is why the heartbeat has to use one — see
  -- ensure_metro(). Change it only if another mod has claimed the same id.
  metro_id = 35,
}

local function load_config()
  local t = tab.load(CONF_FILE)
  if t then
    for k, v in pairs(t) do
      if config[k] ~= nil then config[k] = v end
    end
  end
end

local function save_config()
  util.make_dir(CONF_DIR)
  tab.save(config, CONF_FILE)
end

-- ─────────────────────────────────────────────────────────────────────────
-- Frame encoding
--
-- screen.peek(0,0,128,64) hands back 8192 bytes, one per pixel, valued 0-15.
-- Touching those bytes one at a time from Lua, every frame, is the one thing
-- that could make this mod expensive — so we never do. A single gsub with a
-- translation table converts the whole buffer in one pass inside C, and the
-- per-pixel work never enters the interpreter.
--
-- Sixteen grey levels, THREE pixels in TWO characters. 16^3 == 64^2, so a
-- triple of 4-bit greys is exactly two symbols of a 64-character alphabet,
-- which keeps everything 7-bit ASCII — what OSC says a string is, through a
-- liblo we do not control.
--
-- The cost that matters is the number of datagrams, not their size: matron
-- builds a fresh lo_address per osc.send, so every datagram is its own socket
-- open/sendto/close, and the first hardware test tore and lagged on that. So
-- the frame stays at 4 datagrams. Each band of 2048 pixels gets ONE padding
-- pixel to make 683 whole triples, 1366 characters, 1392 bytes on the wire:
-- under the 1472 a 1500-byte MTU carries without fragmenting.
--
-- Until 2026-10 this sent 8 levels, two pixels per character, because 3 does
-- not divide a row and so no chunking lines up with triples. Padding each band
-- is the answer to that: a triple never has to line up with a row, only with
-- its own band. 8 levels turned every gradient on norns into 8 bands.
-- ─────────────────────────────────────────────────────────────────────────

local W, H = 128, 64
local CHUNKS = 4                          -- 4 datagrams per frame
local CHUNK_PX = (W * H) / CHUNKS         -- 2048 px = 16 rows
local PAD = string.rep(string.char(0), (3 - CHUNK_PX % 3) % 3)
local CHUNK_CHARS = (CHUNK_PX + #PAD) / 3 * 2    -- 1366
local FULL_REFRESH_S = 2.0                -- re-send everything this often, so a
                                          -- panel that joined late or dropped a
                                          -- packet always heals

local ALPHABET =
  "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+-"

-- Keyed by the three-byte string, so gsub("...", xlat3) does the lookup in C.
-- 4096 entries, built once.
local xlat3 = {}
for a = 0, 15 do
  for b = 0, 15 do
    for c = 0, 15 do
      local v = a * 256 + b * 16 + c
      local hi, lo = math.floor(v / 64), v % 64
      xlat3[string.char(a, b, c)] =
        ALPHABET:sub(hi + 1, hi + 1) .. ALPHABET:sub(lo + 1, lo + 1)
    end
  end
end

-- 8192 bytes of 0-15 in, CHUNKS payloads out (indexed from 0), or nil if one
-- came out the wrong length.
--
-- gsub leaves a match alone when the table has no entry for it, which would
-- silently change the payload's length and get every chunk rejected at the far
-- end. xlat3 covers all 4096 triples and screen_peek masks to 0-15, so this
-- cannot happen — but it is the one failure that would look like a dead mirror
-- with no error anywhere, so it says so once rather than never.
local warned_length = false

local function encode(px)
  local out = {}
  for c = 0, CHUNKS - 1 do
    local a = c * CHUNK_PX + 1
    local payload = (px:sub(a, a + CHUNK_PX - 1) .. PAD):gsub("...", xlat3)
    if #payload ~= CHUNK_CHARS then
      if not warned_length then
        warned_length = true
        print("pf-mirror: encoded chunk is " .. #payload .. " chars, expected " ..
              CHUNK_CHARS .. " — the panel will reject these")
      end
      return nil
    end
    out[c] = payload
  end
  return out
end

-- ─────────────────────────────────────────────────────────────────────────
-- Where the panel is
--
-- osc.send must never be given a host NAME. matron's osc_send builds a fresh
-- lo_address for every message and frees it after (matron/src/osc.cc), so
-- liblo resolves the name again on every send, on the Lua thread, blocking.
-- When `patternflow.local` stops resolving (the panel rebooting into new
-- firmware, off the network, up as its own hotspot) each lookup takes seconds
-- to fail. The mirror sends up to nine messages a second, so norns falls
-- further behind than it can ever catch up: the screen, the encoders and the
-- menus all freeze, and the only way out is to remove the mod. That was the
-- "norns appears to hang" on hardware, blamed at first on the knobs.
--
-- So the name is resolved once, by `getent` in a child process through
-- norns.system_cmd, which answers by callback and never blocks Lua. Until it
-- has answered NOTHING is sent. A literal IP in `host` skips all of it. The
-- panel's own packets carry its address too, so once it talks to us we have
-- it whether or not mDNS works from norns.
-- ─────────────────────────────────────────────────────────────────────────

local panel_ip = nil          -- an IPv4 string, or nil: send nothing
local resolving = false
local handshake               -- defined with the handshake below

local function is_ipv4(s)
  return type(s) == "string" and s:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

local function resolve()
  local host = config.host
  if is_ipv4(host) then panel_ip = host return end
  if resolving then return end
  -- It goes into a shell command line, so only what a host name can contain.
  if type(host) ~= "string" or not host:match("^[%w%.%-]+$") then
    print("pf-mirror: host '" .. tostring(host) .. "' is not a host name")
    return
  end
  resolving = true
  norns.system_cmd("getent ahostsv4 " .. host, function(out)
    resolving = false
    if config.host ~= host then return end   -- changed while we waited
    local ip = type(out) == "string" and out:match("^(%d+%.%d+%.%d+%.%d+)")
    if ip then
      local first = (panel_ip == nil)
      panel_ip = ip
      if first and handshake then handshake() end
    end
  end)
end

local last_chunk = {}   -- what the panel is believed to be showing
local last_full = 0
local frame_period = 1 / config.fps
local last_send = 0

-- Sent after a frame's chunks, and by the keepalive timer when nothing
-- changed. Two jobs: tell the panel the frame is complete so it can show it
-- in one go rather than band by band (this is what fixes the tearing), and
-- refresh liveness so the panel does not hand itself back to its pattern.
local function frame_end()
  if not panel_ip then return end
  osc.send({ panel_ip, config.scr_port }, "/pf/scr/end")
end

local function send_frame(payloads, force)
  if not panel_ip then return end
  local dest = { panel_ip, config.scr_port }
  for c = 0, CHUNKS - 1 do
    local payload = payloads[c]
    if force or last_chunk[c] ~= payload then
      last_chunk[c] = payload
      -- Each datagram is a complete statement about its own band of rows, so
      -- the panel needs no reassembly and a lost packet costs those rows
      -- until they next change (or the next full refresh).
      osc.send(dest, "/pf/scr", { c, CHUNKS, payload })
    end
  end
  frame_end()
end

-- ── Test cards ───────────────────────────────────────────────────────────
--
-- For telling a data fault apart from a display fault. They are a MODE, not a
-- one-shot: while one is selected the mirror sends it instead of the screen,
-- so it stays up while you walk around the menus looking at the panel. The
-- first version sent one frame and the very next menu redraw replaced it.
--
--   diag   a one-pixel diagonal crossing every row exactly once, with faint
--          bars every 16 rows at the chunk boundaries. A row that is
--          duplicated, dropped or shifted is a visible step in a straight line.
--   rows   alternate rows lit. Adjacent rows are never equal by construction,
--          so if the panel shows solid bands or pairs, the doubling is
--          happening after the data — in the driver or the panel, not here.
--   line   one lit row, position set by `line y` in the menu. Move it and
--          watch whether the doubling follows: at every position it is
--          systematic, at one position it is specific to those rows.
--   ramp   all 16 grey levels as bands 8 px wide, rising left to right on the
--          top half and falling on the bottom, so every level sits beside its
--          neighbours and the two ends meet in the middle. Hold it next to the
--          norns screen: two bands that look the same on the panel and not on
--          the OLED were lost to the panel's brightness curve, not the wire.
--
-- The panel side answers the same question from the other end: /api/status
-- reports `rowdup`, how many adjacent row pairs are byte-identical in the
-- buffer it is about to draw. With `rows` selected that must be 0. If it is 0
-- and you can still see doubling, the data arrived correct and the panel is
-- what doubled it.

local TEST_MODES = { "off", "diag", "rows", "line", "ramp" }
local test_mode = 1      -- index into TEST_MODES
local test_line = 5      -- the row `line` lights; 5 by default, the reported one
local test_px = nil      -- the card as raw pixels, encoded like any frame

local function build_test_px()
  local mode = TEST_MODES[test_mode]
  if mode == "off" then test_px = nil return end
  local rows = {}
  for y = 0, H - 1 do
    local row
    if mode == "ramp" then
      local cells = {}
      for band = 0, 15 do
        local lvl = (y < H / 2) and band or (15 - band)
        cells[band + 1] = string.rep(string.char(lvl), W / 16)
      end
      row = table.concat(cells)
    else
      local fill = 0
      if mode == "rows" then
        fill = (y % 2 == 0) and 15 or 0
      elseif mode == "line" then
        fill = (y == test_line) and 15 or 0
      elseif mode == "diag" then
        fill = (y % 16 == 0) and 2 or 0
      end
      row = string.rep(string.char(fill), W)
      if mode == "diag" then
        local x = (y * 2) % W
        row = row:sub(1, x) .. string.char(15) .. row:sub(x + 2)
      end
    end
    rows[y + 1] = row
  end
  test_px = table.concat(rows)
end

local function test_card_active()
  return TEST_MODES[test_mode] ~= "off"
end

local function mirror_frame()
  local now = util.time()
  if now - last_send < frame_period then return end
  last_send = now

  local px
  if test_card_active() then
    if not test_px then build_test_px() end
    px = test_px
  else
    local ok, buf = pcall(screen.peek, 0, 0, W, H)
    if not ok or type(buf) ~= "string" or #buf < W * H then return end
    px = buf
  end
  if not px then return end

  local payloads = encode(px)
  if not payloads then return end

  local force = (now - last_full) >= FULL_REFRESH_S
  if force then last_full = now end

  send_frame(payloads, force)
end


-- ─────────────────────────────────────────────────────────────────────────
-- Handshake
--
-- The panel learns where to send its own OSC from the source IP of the first
-- valid packet it receives — but only the IP. The port it replies to is the
-- compile-time PF_OSC_REMOTE_PORT, and norns sends from an ephemeral port, so
-- the panel can never learn 10111 by itself. That is why the firmware needs
-- `#define PF_OSC_REMOTE_PORT 10111`, and why this ping is the whole of the
-- setup on our side. See docs/01-verified-facts.md.
-- ─────────────────────────────────────────────────────────────────────────

local heard_from_panel = 0

handshake = function()
  if not panel_ip then return end
  osc.send({ panel_ip, config.osc_port }, "/patternflow/ping")
end

-- ─────────────────────────────────────────────────────────────────────────
-- Control: panel encoders and buttons -> norns
--
-- _norns.enc / _norns.key are the system input path: identical to a hand on
-- the physical encoder. Menu mode gets it, the running script gets it, and
-- no script has to know this mod exists.
-- ─────────────────────────────────────────────────────────────────────────

local function handle_osc(path, args, from)
  if path:sub(1, 12) ~= "/patternflow" then return end
  heard_from_panel = util.time()
  -- The panel only talks to us once it has been pinged, so this is our panel,
  -- and its source address is the one thing mDNS cannot get wrong. A host the
  -- user typed in as an IP stays theirs.
  if from and is_ipv4(from[1]) and not is_ipv4(config.host) then
    panel_ip = from[1]
  end
  if not (CONTROL_AVAILABLE and config.control) then return end

  local n, ev = path:match("^/patternflow/knob/(%d+)/(%a+)$")
  if n then
    if ev ~= "delta" then return end
    local e = config.enc_map[tonumber(n)]
    local d = tonumber(args[1])
    if e and e > 0 and d and d ~= 0 then
      _norns.enc(e, d)
    end
    return
  end

  n, ev = path:match("^/patternflow/button/(%d+)/(%a+)$")
  if n then
    -- `held` is the level (down on press, up on release), so it alone gives
    -- real key-down/key-up — including long presses. `press` is the same
    -- moment as held-going-high and would double every keypress.
    if ev ~= "held" then return end
    local k = config.key_map[tonumber(n)]
    local z = tonumber(args[1])
    if k and k > 0 and z then
      _norns.key(k, z ~= 0 and 1 or 0)
    end
    return
  end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Wiring
-- ─────────────────────────────────────────────────────────────────────────

local wrapped_screen = false
local wrapped_osc = false
local ping_metro

local function wrap_screen()
  if wrapped_screen then return end
  wrapped_screen = true

  -- Wrap update_default, not update. The screensaver assigns
  -- `Screen.update = function() end` on sleep and `Screen.ping` assigns it
  -- back to `Screen.update_default` on wake — so a wrapper installed on
  -- `update` is silently thrown away the first time the screen sleeps.
  -- update_default is the one funnel to _norns.screen_update() and survives
  -- both assignments.
  local inner = screen.update_default
  screen.update_default = function(...)
    inner(...)              -- the local screen first: never make it wait on us
    if config.mirror then
      local ok, err = pcall(mirror_frame)
      if not ok then print("pf-mirror: mirror error: " .. tostring(err)) end
    end
  end
  -- If the screensaver isn't holding it, point the live field at the wrapper.
  if screen.update == inner then screen.update = screen.update_default end
end

local function wrap_osc()
  if wrapped_osc then return end
  wrapped_osc = true

  -- _norns.osc.event is the core dispatcher that runs before (and
  -- independently of) the script's own osc.event, so chaining here survives
  -- any script redefining osc.event — which scripts routinely do.
  local inner = _norns.osc.event
  _norns.osc.event = function(path, args, from)
    local ok, err = pcall(handle_osc, path, args, from)
    if not ok then print("pf-mirror: osc error: " .. tostring(err)) end
    if inner then inner(path, args, from) end
  end
end

-- The heartbeat. Two jobs: keep the mirror alive on the panel while the norns
-- screen sits still (nothing is redrawn, so nothing else would send anything),
-- and re-ping until the panel has answered, in case it booted after we did.
--
-- It must NOT come from metro.init(). That hands out ids 1..30, and
-- script.lua's cleanup calls metro.free_all(), which stops every one of them —
-- it is stopping the *script's* timers and has no way to know one is ours. So
-- loading any script silently killed the heartbeat, the mirror timed out 1.2 s
-- later, and the panel fell back to its pattern. That was the "pattern keeps
-- popping back up when nothing happens on norns" from the first hardware test.
--
-- metro.lua allocates 36 metros, hands out only the first 30, and frees only
-- the first 30. Ids 31-35 are marked reserved and belong to nobody: exactly
-- this case. `metro[id]` reaches one directly (Metro.__index returns
-- Metro.metros[idx] for a numeric key) and free_all never touches it.
local function ensure_metro()
  ping_metro = metro[config.metro_id]
  if not ping_metro then
    print("pf-mirror: metro " .. tostring(config.metro_id) ..
          " does not exist; the mirror will time out when idle")
    return
  end
  ping_metro.event = function(stage)
    if config.mirror then
      local ok, err = pcall(frame_end)
      if not ok then print("pf-mirror: keepalive error: " .. tostring(err)) end
    end
    -- Every 5 s while the panel is silent: look the name up again (it may
    -- have come back, or moved to another address) and ping. Both are
    -- harmless when there is nothing there — the lookup is in another
    -- process and a ping without an address is not sent.
    if stage % 20 == 0 and util.time() - heard_from_panel > 10 then
      resolve()
      handshake()
    end
  end
  ping_metro:start(0.25)
end

mod.hook.register("system_post_startup", this_name .. "-startup", function()
  load_config()
  frame_period = 1 / math.max(1, config.fps)
  wrap_osc()
  wrap_screen()
  resolve()       -- a literal IP pings now; a name pings when getent answers
  handshake()
  ensure_metro()
end)

-- Insurance, not the mechanism. A reserved metro should survive a script
-- change untouched; this only costs a comparison and means that if some other
-- mod ever does reach into the reserved range, the mirror recovers at the next
-- script change instead of staying dead until a reboot.
mod.hook.register("script_post_cleanup", this_name .. "-cleanup", function()
  if ping_metro and ping_metro.is_running == false then ensure_metro() end
end)

mod.hook.register("system_pre_shutdown", this_name .. "-shutdown", function()
  if ping_metro then ping_metro:stop() end
end)

-- ─────────────────────────────────────────────────────────────────────────
-- Mod menu
-- ─────────────────────────────────────────────────────────────────────────

local m = {}
local sel = 1
local items = {
  { label = "mirror",  kind = "bool",  key = "mirror" },
  { label = "fps",     kind = "int",   key = "fps", min = 1, max = 40 },
  { label = "host",    kind = "text",  key = "host" },
  { label = "test",    kind = "test" },
  { label = "line y",  kind = "line" },
  { label = "re-ping", kind = "action", fn = function() resolve() handshake() end },
}
-- Six rows is all the screen holds (see redraw). With control offered as well
-- there were seven, and re-ping was drawn at y=65, off the bottom.
if CONTROL_AVAILABLE then
  table.insert(items, 1, { label = "control", kind = "bool", key = "control" })
end

m.key = function(n, z)
  if z ~= 1 then return end
  if n == 2 then
    save_config()
    mod.menu.exit()
  elseif n == 3 then
    local it = items[sel]
    if it.kind == "bool" then
      config[it.key] = not config[it.key]
    elseif it.kind == "action" and it.fn then
      local ok, err = pcall(it.fn)
      if not ok then print("pf-mirror: " .. it.label .. ": " .. tostring(err)) end
    end
    mod.menu.redraw()
  end
end

m.enc = function(n, d)
  if n == 2 then
    sel = util.clamp(sel + d, 1, #items)
  elseif n == 3 then
    local it = items[sel]
    if it.kind == "test" then
      test_mode = util.clamp(test_mode + d, 1, #TEST_MODES)
      build_test_px()
      last_chunk = {}       -- the panel is showing something else entirely
    elseif it.kind == "line" then
      test_line = util.clamp(test_line + d, 0, H - 1)
      build_test_px()
      last_chunk = {}
    elseif it.kind == "int" then
      config[it.key] = util.clamp(config[it.key] + d, it.min, it.max)
      if it.key == "fps" then frame_period = 1 / math.max(1, config.fps) end
    elseif it.kind == "bool" then
      config[it.key] = d > 0
    end
  end
  mod.menu.redraw()
end

m.redraw = function()
  screen.clear()
  screen.level(4)
  screen.move(0, 8)
  local age = util.time() - heard_from_panel
  local state = (not panel_ip) and (resolving and "finding panel" or "no address")
    or (age < 10 and "linked" or "no panel")
  screen.text(this_name .. "  " .. state)
  -- 8px pitch from y=17: six rows land at 17..57 and clear the 64px screen.
  -- At the 10px pitch this used the sixth row was drawn off the bottom.
  for i, it in ipairs(items) do
    local y = 9 + i * 8
    screen.level(i == sel and 15 or 3)
    screen.move(0, y)
    screen.text(it.label)
    local v
    if it.kind == "test" then
      v = TEST_MODES[test_mode]
    elseif it.kind == "line" then
      v = (TEST_MODES[test_mode] == "line") and test_line or "-"
    elseif it.kind ~= "action" then
      v = config[it.key]
      if type(v) == "boolean" then v = v and "on" or "off" end
    end
    if v ~= nil then
      screen.move(127, y)
      screen.text_right(tostring(v))
    end
  end
  screen.update()
end

m.init = function() load_config() end
m.deinit = function() save_config() end

mod.menu.register(this_name, m)

pf.config = config
pf.version = VERSION
pf.handshake = function() handshake() end
pf.panel_ip = function() return panel_ip end

-- Exposed so the offline tests can drive the menu the way a hand would,
-- rather than reaching into upvalues. See tools/test_mod.lua.
pf.menu = m
pf.items = items
pf.select = function(i) sel = i end
pf.test_mode_name = function() return TEST_MODES[test_mode] end
-- So the tests can prove both that control is off and that the routing it
-- would turn back on still works. Nothing on norns calls this.
pf.set_control_available = function(on) CONTROL_AVAILABLE = on end

return pf
