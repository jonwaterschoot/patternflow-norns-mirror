-- patternflow — norns ⇄ Patternflow bridge (system mod)
--
-- Three jobs, each independently switchable from the mod menu:
--
--   control   the panel's encoders and buttons drive norns as if they were
--             the physical ones. Works under every script, changes none.
--   mirror    the norns screen is sent to the panel's `screencast` feature.
--   handshake tells the panel where we are, so its own OSC output finds us.
--
-- All of it is plain Lua. No native build, no norns fork.
-- The facts this is written against are in docs/01-verified-facts.md.
--
-- Install: copy this directory to ~/dust/code/patternflow/ on norns, then
-- SYSTEM > MODS > patternflow > enable, and restart.

local mod = require 'core/mods'
local tab = require 'tabutil'
local util = require 'util'

local this_name = mod.this_name or "patternflow"

local pf = {}

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

  control = true,
  mirror = true,

  fps = 20,          -- mirror cap; the screen rarely changes faster than this

  enc_map = { 1, 2, 3, 0 },  -- panel knob N -> norns encoder (0 = leave to the panel)
  key_map = { 1, 2, 3, 0 },  -- panel button N -> norns key
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
-- 256-entry translation table turns the whole buffer into hex in one pass
-- inside C, and the per-pixel work never enters the interpreter.
--
-- One hex character per pixel keeps all 16 grey levels (which is what the
-- hue control needs to shade against) and stays inside 7-bit ASCII, which is
-- what OSC says a string is. Packing two pixels into one byte would halve the
-- traffic but needs 225+ distinct byte values, i.e. the high half of the
-- range — outside the spec, through a liblo we don't control. Not worth it:
-- the dirty-chunk check below already removes most of the traffic.
-- ─────────────────────────────────────────────────────────────────────────

local W, H = 128, 64
local CHUNKS = 8                      -- 8 datagrams of 1024 px = 8 rows each
local CHUNK_PX = (W * H) / CHUNKS     -- 1024
local FULL_REFRESH_S = 2.0            -- re-send everything this often, so a
                                      -- panel that joined late or dropped a
                                      -- packet always heals

local HEX = "0123456789abcdef"
local xlat = {}
for v = 0, 255 do
  -- peek should only ever give 0-15; the mask keeps a surprise from
  -- indexing off the end of the alphabet.
  local lvl = v % 16
  xlat[string.char(v)] = HEX:sub(lvl + 1, lvl + 1)
end

local last_chunk = {}   -- what the panel is believed to be showing
local last_full = 0
local frame_period = 1 / config.fps
local last_send = 0

local function mirror_frame()
  local now = util.time()
  if now - last_send < frame_period then return end
  last_send = now

  local ok, buf = pcall(screen.peek, 0, 0, W, H)
  if not ok or type(buf) ~= "string" or #buf < W * H then return end

  local hex = buf:gsub(".", xlat)

  local force = (now - last_full) >= FULL_REFRESH_S
  if force then last_full = now end

  local dest = { config.host, config.scr_port }
  for c = 0, CHUNKS - 1 do
    local a = c * CHUNK_PX + 1
    local payload = hex:sub(a, a + CHUNK_PX - 1)
    if force or last_chunk[c] ~= payload then
      last_chunk[c] = payload
      -- Every datagram is a complete, idempotent statement about its own
      -- rows, so the panel needs no reassembly and a lost packet costs
      -- those rows until they next change (or the next full refresh).
      osc.send(dest, "/pf/scr", { c, CHUNKS, payload })
    end
  end
end

-- Tells the feature we're still here when the screen is static and the loop
-- above is sending nothing at all. Without it the panel would decide the
-- mirror had gone away and hand the panel back to the running pattern.
local function mirror_ping()
  osc.send({ config.host, config.scr_port }, "/pf/scr/ping")
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

local function handshake()
  osc.send({ config.host, config.osc_port }, "/patternflow/ping")
end

-- ─────────────────────────────────────────────────────────────────────────
-- Control: panel encoders and buttons -> norns
--
-- _norns.enc / _norns.key are the system input path: identical to a hand on
-- the physical encoder. Menu mode gets it, the running script gets it, and
-- no script has to know this mod exists.
-- ─────────────────────────────────────────────────────────────────────────

local function handle_osc(path, args)
  if path:sub(1, 12) ~= "/patternflow" then return end
  heard_from_panel = util.time()
  if not config.control then return end

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
      if not ok then print("patternflow: mirror error: " .. tostring(err)) end
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
    local ok, err = pcall(handle_osc, path, args)
    if not ok then print("patternflow: osc error: " .. tostring(err)) end
    if inner then inner(path, args, from) end
  end
end

mod.hook.register("system_post_startup", this_name .. "-startup", function()
  load_config()
  frame_period = 1 / math.max(1, config.fps)
  wrap_osc()
  wrap_screen()

  handshake()
  -- One timer covers both keepalives: re-ping until the panel has spoken to
  -- us (it may have booted after we did), and tell the screencast feature
  -- we're alive while the screen sits still.
  ping_metro = metro.init()
  ping_metro.time = 0.25
  ping_metro.event = function(stage)
    if config.mirror then mirror_ping() end
    if stage % 20 == 0 then
      if util.time() - heard_from_panel > 10 then handshake() end
    end
  end
  ping_metro:start()
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
  { label = "control",  kind = "bool",  key = "control" },
  { label = "mirror",   kind = "bool",  key = "mirror" },
  { label = "fps",      kind = "int",   key = "fps", min = 1, max = 30 },
  { label = "host",     kind = "text",  key = "host" },
  { label = "re-ping",  kind = "action" },
}

m.key = function(n, z)
  if z ~= 1 then return end
  if n == 2 then
    save_config()
    mod.menu.exit()
  elseif n == 3 then
    local it = items[sel]
    if it.kind == "bool" then
      config[it.key] = not config[it.key]
    elseif it.kind == "action" then
      handshake()
    end
    mod.menu.redraw()
  end
end

m.enc = function(n, d)
  if n == 2 then
    sel = util.clamp(sel + d, 1, #items)
  elseif n == 3 then
    local it = items[sel]
    if it.kind == "int" then
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
  screen.text("patternflow  " .. (age < 10 and "linked" or "no panel"))
  for i, it in ipairs(items) do
    local y = 8 + i * 10
    screen.level(i == sel and 15 or 3)
    screen.move(0, y)
    screen.text(it.label)
    if it.kind ~= "action" then
      screen.move(127, y)
      local v = config[it.key]
      if type(v) == "boolean" then v = v and "on" or "off" end
      screen.text_right(tostring(v))
    end
  end
  screen.update()
end

m.init = function() load_config() end
m.deinit = function() save_config() end

mod.menu.register(this_name, m)

pf.config = config
pf.handshake = handshake
return pf
