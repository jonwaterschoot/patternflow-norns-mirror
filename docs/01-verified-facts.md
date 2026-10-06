# 01 — Verified facts

Everything here was read out of the actual source, not recalled. Each claim
carries the file it came from so you can re-check it after an upstream change.
Both trees are vendored under `vendor/` as submodules — the paths below are
relative to those.

Verified **2026-09-14** against `engmung/Patternflow@main` (pushed 2026-09-13)
and `monome/norns@main`; Patternflow facts re-checked against **v3.11.0** on
2026-10-04, and the norns OSC and `screen.peek` notes added 2026-10-05.

> If you change one of these facts, change it here first. The rest of the docs
> and all the code are written against this page.

---

## Patternflow

### Hardware
| | |
|---|---|
| MCU | ESP32-S3-WROOM-1 N16R8 — 16 MB flash, 8 MB PSRAM |
| Panel | 128 × 64 HUB75 RGB, P2.5 (320 × 160 mm) |
| Input | 4 × EC11 rotary encoder, each with a push switch |

**128 × 64 is exactly the norns screen geometry.** That is the coincidence this
whole project stands on: a norns frame maps to the panel one pixel to one pixel,
no scaling, no letterboxing.

### The feature system is the integration point, and forking is *not* required

`FEATURE_GUIDE.md` and `firmware/patternflow/features/features.h` both spell out
an **out-of-tree composition** path, in as many words:

> Somebody else's firmware, in their own repository. Their features and their
> `features_local.h` are copied over a checkout of core, which makes their build
> a file copy rather than a merge.

So the arrangement is: Patternflow core stays a pristine submodule, our feature
and our two composition files live in this repo, and the build copies ours over
a checkout of theirs. Taking an upstream update is `git checkout <newer tag>` in
the submodule. There is nothing to merge, ever.

This supersedes the earlier assumption that we would fork Patternflow. We don't.

Two hard rules come with it:

- **Never edit a core file** (`firmware/patternflow/patternflow.ino`,
  `firmware/patternflow/src/`). CI enforces it with
  `firmware/toolchain/check_boundaries.py` — the check is that no core file may
  so much as *name* a feature.
- A feature is a directory `features/<name>/` holding `feature_<name>.h` (its
  descriptor) plus whatever `core_<name>*.h` internals it needs.

An **edition** is core plus a chosen feature set, described by two non-core
files: `features_local.h` (includes + `PF_FEATURE_LIST` in dispatch order) and
`overrides.h` (`#ifndef`-guarded settings, including `PF_VARIANT` and
`PF_VARIANT_VERSION`).

Stock editions (`firmware/bundles/`, as of v3.11.0): **audio** (`osc`, `audio`,
`audio_in`, `midi`) and **performance** (clock, weather, MQTT, show) are the two
upstream ships. **clock** and **midi** (USB-MIDI, built in its own PlatformIO
env) stay in the tree only so CI keeps compiling them. The default build
carries *no* features.

### The `PFFeature` hook table

From `firmware/patternflow/features/pf_feature.h`. Every hook is optional; a
null field means that moment passes the feature by. New fields are appended at
the tail only, never inserted — the descriptors are positional aggregate
initializers.

| hook | when | notes |
|---|---|---|
| `setup()` | boot, before Wi-Fi | load NVS settings, allocate |
| `onNetwork()` | Wi-Fi connect edge **and every reconnect** | start sockets, register HTTP routes here |
| `loop(const PFFeatureFrame&)` | every frame | **must not block** — no `delay()`, no waiting on a socket |
| `observeFrame(const InputFrame&, const PFFeatureFrame&)` | after all input sources merge | read-only by convention |
| `fillInput(InputFrame&)` | before the pattern sees input | this is how you drive a knob from a sensor or a stream |
| `onUserInput()` | a human touched a knob or button | |
| `claimsPattern()` | — | while true, the sketch ignores pattern-change requests from OSC/MQTT/HTTP |
| `takePattern(int*)` | — | *request* a pattern switch; the sketch performs it |
| `onSleep(bool)` / `requestSleep(bool*)` | | |
| `drawOverlay(const PFFeatureFrame&)` | after the pattern draws, before present | GFX primitives straight onto the panel; cheap, for a few glyphs |
| **`composeFrame(const uint8_t* frame, int w, int h)`** | the finished canvas, **before the blit** | **this is the screencast hook** — see below |
| `handleSelectInput` / `drawSelect` / `decorateSelect` | SELECT screen | lets a feature own the pattern browser |
| `appendStatus(String&)` | `/api/status` is built | write `,"key":value` pairs, leading comma, no trailing |
| `cap` | — | the string this feature contributes to `/api/status` caps |
| `navPath` / `navLabel` / `navDesc` | — | the feature's console page, listed without the core naming it |
| `shortName` + `isRuntimeEnabled` / `setRuntimeEnabled` | — | expose both and the device's own NETWORK screen gets a toggle row for your feature |

**`composeFrame` is the one that makes the mirror possible**, and it is better
than what the earlier notes assumed. Its contract, verbatim from the header:

> Return a buffer to show instead (the feature's own scratch, `w*h*3` bytes,
> RGB888 row-major) or null to leave the frame alone. Never write into `frame`:
> it is the pattern's canvas and may be the state the pattern carries into its
> next frame. […] a full pass over the frame is ~8 k pixels and must stay well
> under a millisecond.

So the mirror does not fight the running pattern and does not need to stop it:
while frames are arriving we return our own RGB888 buffer; when they stop we
return `null` and the pattern comes straight back. The `clock` feature is the
first user of `composeFrame` and is the one to read for shape.

A feature's HTTP handlers run on the **network core (Core 0)** while `loop()`
renders on Core 1. A handler that touches what the frame is using right now must
wrap that part in `PFLoopSync::run([&]{ ... })` (`src/core_loop_sync.h`).

### `InputFrame` — and what "lanes" actually are

From `firmware/patternflow/src/core_encoders.h`. Mirrored byte-for-byte by
`abi/pf_abi.h::PFInputFrame`, so pattern modules see the same layout.

```c
struct InputFrame {
  long     knobs[4];              // absolute accumulated clicks
  int      knobDeltas[4];         // this frame's change
  bool     btnPressed[4];         // edge
  bool     btnHeld[4];            // level
  uint32_t now;                   // millis()

  bool     knobAudioActive[4];    // audio-react source state:
  float    knobAudioValue[4];     //   normalized 0..1, turned into virtual knobDeltas

  bool     paramAbsoluteActive[4];// absolute Director bus (MQTT param/1..4)
  uint16_t paramAbsolute[4];      //   wire scale 0..1000
};
```

The "4 lanes 0..1" from the earlier notes are `knobAudioValue[4]` /
`knobAudioActive[4]`. There is no separate lane concept and **no new OSC route is
needed to feed them**: a feature writes them from `fillInput`, and the main loop
turns them into virtual knob deltas so that *ordinary patterns need no
audio-specific code*. Feeding norns's amplitude into a lane is therefore a
`fillInput` hook in our own feature, not a change to the OSC feature.

### The OSC feature — ports, vocabulary, and the port gotcha

From `features/osc/osc_config.h`, `features/osc/core_osc.h`,
`features/osc/feature_osc.h`.

| setting | default |
|---|---|
| `PF_OSC_ENABLED` | `1` (on, in any edition that carries the feature) |
| `PF_OSC_LOCAL_PORT` | **9001** — the panel listens here |
| `PF_OSC_REMOTE_PORT` | **9000** — where the panel sends |
| `PF_OSC_REMOTE_HOST` | `""` — empty means auto-learn |
| `PF_OSC_OUT_LANE_MOTION` | `0` — knob motion caused by a *lane* is not reported out |

**The gotcha, now with its mechanism.** Auto-learn learns the sender's **IP
only**:

```c
IPAddress sender = udp.remoteIP();
if (!remoteValid || sender != remoteIp) { remoteIp = sender; ... }
```

and every outgoing packet then goes to `udp.beginPacket(remoteIp, PF_OSC_REMOTE_PORT)`
— the *compile-time* port, never a learned one. Since norns sends from an
ephemeral source port (see below), the panel would happily learn the norns IP and
then reply to port 9000, where nothing is listening.

**Therefore: `#define PF_OSC_REMOTE_PORT 10111` in `patternflow_secrets.h`.**
The earlier notes had this right; this is the reason it's right.

Leave `PF_OSC_REMOTE_HOST` empty and let the panel learn the norns IP from the
first packet norns sends. That works because the IP half of auto-learn is
correct — it's only the port half that can't apply to norns.

**Accepted by the panel** (`core_osc.h`):

| address | args |
|---|---|
| `/patternflow/knob/N/delta` | int or float, N = 1..4 — *relative*, added on top of the physical encoders |
| `/patternflow/pattern/index` | int or float |
| `/patternflow/content/toggle` | none |
| `/patternflow/ping` | none — asks for a full announce, and is how the panel learns the host |

**Sent by the panel:**

| address | value |
|---|---|
| `/patternflow/knob/N/delta` | clicks moved this frame |
| `/patternflow/knob/N/clicks` | absolute accumulated |
| `/patternflow/button/N/press` | `1` on the press edge |
| `/patternflow/button/N/held` | `1` / `0` on the hold edge |
| `/patternflow/pattern/index`, `/pattern/name`, `/content/mode`, `/app/mode` | on change |
| `/patternflow/hello`, `/version`, `/ip` | on connect, and answering a ping |
| `/patternflow/heartbeat` | uptime seconds |

**Both OSC buffers are 256 bytes** (`uint8_t packet[256]`, `uint8_t rxBuf[256]`),
and a datagram larger than `rxBuf` is flushed and dropped. A screen frame cannot
travel over the OSC feature — this is the concrete reason the mirror needs its
own socket, and it is a size check in the code, not a matter of taste.

`PF_OSC_RX_BUDGET` caps how many datagrams are drained per frame so a flooding
sender can't build up queue latency. Our feature should do the same.

### "The device never streams pixels" — what the rule actually covers

From `docs/rest-api.md`:

> A device-streamed frame preview (`GET /api/frame`, 24 KB per poll) was built,
> shipped and removed the same day: polling it while a pattern module was
> resident captured the render loop for seconds at a time and piled requests up
> until the device read as dead. […] the device never streams pixels.

Read it precisely. It is a rule about the **HTTP API**, about **device → host**,
and its stated cause is that *HTTP polling captured the render loop*. `/api/knob`
and `/remote` were removed in the same incident and the doc says not to look for
them.

What that means for us:

- It is **not** a prohibition on host → device pixels over a feature's own UDP
  socket. That path did not exist and was not what failed.
- The *engineering lesson* transfers completely and we obey it: the receive path
  must be a bounded drain of a non-blocking socket, never a blocking read, and
  `composeFrame` must stay well under a millisecond.

Also from the same doc, useful for the reverse direction (panel → norns screen):
`GET /api/patterns/<slug>?ext=thumb` returns `PFT1` + width/height as LE u16,
then 128×64 **RGB565** (16,392 bytes) — the panel's own last-drawn frame for that
pattern. It is a poll, it 404s until the pattern has run, and a poll interval
under a second is documented as "a bug rather than a feature".

### Where a pattern module lives — and why its size stopped mattering

From `firmware/patternflow/src/core_module_memory.h` and
`src/core_module_loader.h`, as of **v3.11.0** (the code move landed in 3.10.5,
the data move in 3.11.0).

Before 3.10.5 a module's executable sections could only live in internal RAM —
the same heap lwIP, the console and every feature run on — and the loader
refused any module whose `codeBytes + PF_MODULE_INTERNAL_RESERVE` (24576) did
not fit in what was free. That is the `code N B needs M free, have K` error,
and the Audio edition's features left too little for patterns of ~8 KB of code
and up ([06-hardware-findings.md](06-hardware-findings.md#some-patterns-would-not-load--fixed-upstream)).

From 3.10.5, on the S3, `PF_MODULE_CODE_POLICY` defaults to
`PF_MODULE_CODE_PSRAM_FIRST`: the code is placed in PSRAM and fetched through
the instruction-bus alias of the same page. `admitCode()` then admits a module
whenever PSRAM can take its code, and the internal-RAM comparison only decides
the outcome if this unit has been **demoted** — a PSRAM placement that failed
to read back, after which it keeps code internal until reboot. From 3.11.0 the
data sections go to PSRAM first as well (`PF_MODULE_DATA_PSRAM_FIRST`).

Upstream's measurement: on the Audio edition, internal heap with a module
resident is ~27.8 KB whatever the size of its code, and a 32 KB-code module
that was refused before now loads. The cost is 0–5% frame time on code-heavy
modules (instruction-cache misses).

`/api/status` → `moduleMemory`:

| field | |
|---|---|
| `codePolicy` | `2` as built; `0` means this unit has been demoted since boot, and the old refusal is back |
| `serviceFree`, `budget` | internal free, and free − reserve. Still published; no longer the admission test under policy 2 |
| `resident` | `count`, `bytes`, `resumes`, `evictions` — modules kept loaded in PSRAM after another pattern took over (3.11.0, `core_module_resident.h`) |

Residency matters to the mirror: the screencast swaps in the hidden `Black`
preset while live and asks for the previous pattern back afterwards. That
return is now a resume (~0.2 ms), not a reload with `setup()` run again.

---

## norns

### The screen is readable *and* writable from plain Lua

`vendor/norns/lua/core/screen.lua`:

```lua
-- get a rectangle of screen content. returned buffer contains one byte
-- (valued 0 - 15) per pixel, i.e. w * h bytes
Screen.peek = function(x, y, w, h) return _norns.screen_peek(x, y, w or 1, h or 1) end

-- set a rectangle of screen content.
Screen.poke = function(x, y, w, h, s) _norns.screen_poke(x, y, w, h, s) end
```

`screen.peek(0, 0, 128, 64)` returns **8192 bytes, one per pixel, valued 0–15**.

This settles a contradiction in the archived notes: the old README said `peek`
exists, the old screencast README said "there's no Lua API to read its own
framebuffer". The README was right. The capture half needs no norns fork and no
native build.

`screen.poke` existing is what makes the panel → norns direction possible later,
should we want it.

### OSC on norns

- **Default receive port: 10111** (`matron/src/args.cc`, `remote_port`). Also
  `8888` local, `57120` ext (sclang), `9999` crone.
- `osc.send({host, port}, path, args)` — `matron/src/weaver.cc::_osc_send`.

Two limits, both load-bearing, both read out of the marshalling switch:

```c
case LUA_TNIL:     lo_message_add_nil(msg);    break;
case LUA_TNUMBER:  lo_message_add_float(msg, lua_tonumber(l, -1)); break;
case LUA_TBOOLEAN: lo_message_add_true/false(msg); break;
case LUA_TSTRING:  lo_message_add_string(msg, lua_tostring(l, -1)); break;
default:           luaL_error(l, "invalid osc argument type %s", ...);
```

1. **norns cannot send an OSC blob.** Only nil, float, boolean, string. The
   archived notes left "use a blob if norns can send one" as an open question —
   it can't. A null-free text encoding of the frame is mandatory, not a fallback.
2. **Every Lua number goes out as a float32**, never int32. Our frame header
   fields (sequence, chunk index) arrive as `f`, so the panel-side parser must
   accept `f` as well as `i` for them.
3. `lo_message_add_string` takes a C string, so **no embedded NULs** — which is
   the same constraint from the other direction.

And the source port, from `matron/src/osc.cc`:

```c
void osc_send(const char *host, const char *port, const char *path, lo_message msg) {
    lo_address address = lo_address_new(host, port);
    lo_send_message(address, path, msg);
    lo_address_free(address);
}
```

A fresh `lo_address` per send, so the datagram leaves from an **ephemeral source
port** — not 10111. This is exactly why the panel's auto-learn can give us the
right IP and the wrong port, and why `PF_OSC_REMOTE_PORT` must be pinned.

The same three lines have a second consequence, found on hardware
(2026-10-05): **a host name is resolved again on every send**, inside
`lo_send_message`, on matron's Lua thread, blocking. Nothing caches it,
because the address is freed straight after. While `patternflow.local`
resolves that costs little; when it stops resolving (the panel rebooting into
new firmware, off the network, up as its own hotspot) every lookup takes
seconds to fail, measured at 6.7 s from a desktop on the same network. A
mirror sending several messages a second then freezes norns outright —
screen, encoders, menus — until the mod is removed. So **never pass a name to
`osc.send` on a hot path.** The mod resolves once, with `getent` through
`norns.system_cmd` (`lua/core/norns.lua`: runs in a child process, answers by
callback — `_system_cmd` in `weaver.cc` only queues it), and sends to the IP.

`screen.peek` is blocking too, in a different way: `_screen_peek` posts a
request to the screen thread and `sem_wait`s for the answer
(`weaver.cc`, `screen_results.cc`). `screen_peek` in `hardware/screen.cc`
returns *without* posting on two error paths (`malloc` failing, and
`cairo_image_surface_get_data` returning NULL, logged as
`ERROR: screen_peek: no data`), and the waiting Lua thread would then never
wake. Not seen to happen; written down because it would look the same.

### norns answers `/remote/enc` and `/remote/key` out of the box

This is the find that reorders the roadmap. `vendor/norns/lua/core/osc.lua`:

```lua
_norns.osc.event = function(path, args, from)
  if OSC.event ~= nil then OSC.event(path, args, from) end
  if util.string_starts(path, "/param") then      param_handler(path, args)
  elseif util.string_starts(path, "/remote") then remote_handler(path, args) end
end
```

`remote_handler` maps:

| address | effect |
|---|---|
| `/remote/enc/<n> <delta>` (or `/remote/enc {n, delta}`) | `_norns.enc(n, delta)` |
| `/remote/key/<n> <z>` (or `/remote/key {n, z}`) | `_norns.key(n, z)` |
| `/remote/brd …` | keyboard events |

and `param_handler` maps `/param/<id> <v>` and `/param/<pset>/<id> <v>` straight
onto a paramset.

Three things follow:

- `_norns.enc` / `_norns.key` are the **system** input path — identical to
  turning the physical encoder. Menu mode gets it, script mode gets it, whatever
  is loaded gets it. **No script changes, no mod, for any of it.**
- These handlers run *in addition to* the script's own `osc.event`, so they work
  under every script and never conflict with one.
- Therefore "use the panel's 4 encoders to control a norns script" is a
  translation job — `/patternflow/knob/N/delta` → `/remote/enc/n` — and nothing
  more. It needs no firmware work at all.

### Mods

`mod.hook.register(which, name, func)`. Available hooks
(`vendor/norns/lua/core/hook.lua`): `script_pre_init`, `script_post_init`,
`script_post_cleanup`, `audio_post_restore_default_routing`,
`system_post_startup`, `system_pre_shutdown`.

There is **no per-redraw hook**. `ndi-mod` gets one by monkey-patching
`norns.script.refresh` and `screen.update` from `script_post_init` — the same
technique our mirror uses.

---

## What this changes about the plan

| earlier assumption | what the source says |
|---|---|
| We fork Patternflow | We don't. Out-of-tree composition is the documented, CI-enforced path: core stays a clean submodule. |
| The panel-side draw is a vague "per-frame draw hook" | It's `composeFrame`, which blends before the blit and yields back to the pattern by returning `null`. |
| Feeding audio lanes needs a new `/pf/lane/N` OSC route | It needs a `fillInput` hook writing `knobAudioValue[]`. No new wire protocol. |
| Maybe norns can send OSC blobs | It cannot. Text encoding is mandatory. Also: every number is a float32. |
| Panel encoders → norns script is milestone M3-ish | norns already answers `/remote/enc`. It's the *cheapest* thing here, not the dearest, and it comes before the mirror. |
| `PF_OSC_REMOTE_PORT 10111` (asserted) | Confirmed, and the mechanism is understood: auto-learn captures IP only. |
| "norns has no Lua framebuffer read" (screencast README) | Wrong. `screen.peek` is stock. |
