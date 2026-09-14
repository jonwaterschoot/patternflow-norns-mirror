# 02 — Wire protocol

Three conversations run between the two devices, on three ports. They are
independent: any one of them works with the other two switched off.

```
                  norns  (10111 in, ephemeral out)
                    │  ▲
     screen frames  │  │  knob + button events
     /pf/scr        │  │  /patternflow/knob/N/delta
                    ▼  │  /patternflow/button/N/held
              Patternflow
              9002 (screencast)   9001 (osc)
```

| port | who listens | carries |
|---|---|---|
| **10111** | norns | everything the panel sends |
| **9001** | panel, `osc` feature | the handshake ping; anything else a host wants to drive |
| **9002** | panel, `screencast` feature | screen frames |

Why frames get their own port: the OSC feature's receive buffer is 256 bytes
and it drops any datagram larger than that. A frame chunk is about 1060. This
is a bounds check in `core_osc.h`, not a preference.

---

## 1. Handshake — norns → panel, port 9001

```
/patternflow/ping        (no arguments)
```

Sent by the mod at startup and re-sent every five seconds until the panel
answers. It exists for one reason: **the panel has no other way to learn where
norns is.**

The panel learns its remote from the source IP of the first valid OSC packet
it receives, and only the IP — it always sends to the compile-time
`PF_OSC_REMOTE_PORT`. matron builds a fresh `lo_address` per `osc.send`, so
norns's packets leave from an ephemeral source port that would be useless to
learn anyway.

So the two halves of the setup are: norns pings (this message), and the
firmware is built with `PF_OSC_REMOTE_PORT 10111`. Neither works alone.

---

## 2. Control — panel → norns, port 10111

Stock Patternflow output, no firmware change. The mod translates it to norns's
own built-in remote-control vocabulary.

| the panel sends | the mod calls | effect |
|---|---|---|
| `/patternflow/knob/N/delta  <int>` | `_norns.enc(n, delta)` | as if you turned norns encoder *n* |
| `/patternflow/button/N/held <0\|1>` | `_norns.key(n, z)` | as if you pressed norns key *n* |

Default mapping is 1→1, 2→2, 3→3, and **channel 4 is left alone**: long-pressing
panel encoder 4 is how the panel switches its own patterns, and knob 4 is the
mirror's hue control.

Two deliberate omissions:

- `/patternflow/knob/N/clicks` (the absolute count) is ignored. norns encoders
  are relative; feeding it absolute values would make every reconnect jump.
- `/patternflow/button/N/press` is ignored. It fires at the same moment `held`
  goes high, so honouring both would double every keypress. `held` alone gives
  a real down and up, which is what long-presses need.

Because `_norns.enc` and `_norns.key` are the *system* input path, this works
under every script and under the menus, and no script has to know about it.

norns also answers `/param/<id> <value>` and `/param/<pset>/<id> <value>` out
of the box, if you would rather drive a specific parameter than an encoder.
Nothing in this project uses it, but it costs nothing and it is there.

---

## 3. The mirror — norns → panel, port 9002

```
/pf/scr      ,ffs   chunk, nchunks, payload
/pf/scr/end  (no arguments)
```

`chunk` and `nchunks` are floats because **norns cannot send anything else**:
matron marshals every Lua number with `lo_message_add_float`. The panel-side
parser accepts `i` as well, so a desktop test rig can speak the same protocol
without a second code path.

### The payload

One character per **pixel pair**, packed as `a * 8 + b` into a 64-character
alphabet, where `a` and `b` are 3-bit grey levels, row-major from the top-left:

```
0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+-
```

With the mod's `nchunks = 4` each chunk carries 2048 pixels — exactly 16 rows —
as 1024 characters, and the datagram lands around 1060 bytes: comfortably
inside a 1500-byte MTU, no IP fragmentation.

Three properties, each of which bought something:

**Every datagram is complete and idempotent.** Chunk *c* covers pixels
`[c·px, (c+1)·px)` and says everything about them. There is no reassembly
buffer and no sequence number. A dropped packet costs those rows until they
next change or until the mod's two-second full refresh comes round.

**Only changed chunks are sent.** The mod keeps the last payload per chunk and
compares. A static norns screen sends no chunks at all; typing in the parameter
menu sends one.

**Encoding is a single pass in C.** `screen.peek` hands back 8192 bytes and the
mod converts them with one `string.gsub(buf, "..", table)` against a 256-entry
table keyed by the two-byte pair. The per-pixel work never enters the Lua
interpreter, which is the whole reason a pure-Lua mirror is viable.

### Why 8 grey levels and not 16

The first version sent one hex character per pixel and kept all 16 of norns's
levels. On hardware, moving content lagged. The cost was not the bytes so much
as the **datagram count**: matron builds a fresh `lo_address` for every
`osc.send`, so each datagram is its own socket open, sendto and close. Eight
per frame at 20 fps is 160 of those a second.

Pairing pixels halves it to four. Keeping 16 levels in a pair would need 256
symbols — the high half of the byte range, outside OSC's "non-null ASCII", sent
through a liblo we do not control. 8 levels is the honest trade, and norns's UI
is mostly full-on, full-off and a few dim greys.

Three pixels in two characters would keep all 16 levels at the same size
(16³ = 64² exactly), but 3 divides neither a 128-pixel row nor a 64-row screen,
so no chunking lines up with it. That is the only reason it is not what this
does.

### `/pf/scr/end` — frame complete

Sent after a frame's chunks, and four times a second by the mod's heartbeat
when nothing has changed. It does two jobs.

**It publishes the frame.** The panel decodes chunks into a back buffer and
only copies it forward on this message. Without it the panel showed each band
the instant it arrived, and a frame was visibly drawn top to bottom — which is
exactly what the first hardware test looked like.

The copy is a copy and not a pointer swap on purpose: unchanged bands are never
re-sent, so the back buffer has to keep carrying the last complete picture.
Swapping would leave it holding the frame before last, and any band that had
not changed since would flick between the two.

**It is the liveness beacon.** A static norns screen sends no chunks, so
without a beat the panel would decide the mirror had gone away and hand itself
back to the running pattern.

The heartbeat that sends it has to come from one of norns's **reserved metros
(31–35)**. `metro.init()` hands out 1–30, and `script.lua`'s cleanup calls
`metro.free_all()`, which stops all of those — it is stopping the script's
timers and cannot know one is ours. On the first hardware test the heartbeat
was on a script metro, so loading any script silently killed it and the pattern
came back a second later.

### Liveness window

The panel treats the mirror as live for `PF_SCREENCAST_TIMEOUT_MS` (1200 ms)
after any packet — long enough to ride out a couple of lost beats.

### While the mirror is up, the pattern stands down

The running pattern would otherwise render a full frame every frame for
`composeFrame` to discard — invisible work competing with the blit. So the
feature asks for the `Black` preset when the mirror goes live and asks for the
previous pattern back when it stops. It only ever *asks*: loading a module is
the sketch's job, and if a host or a hand chooses a pattern while mirroring,
that choice is newer and is left alone.

### The cost that shapes all of this

`matron`'s `osc_send` builds a fresh `lo_address` for every call and frees it
after (`matron/src/osc.cc`). liblo creates the UDP socket lazily on first send
against an address and closes it when the address is freed, so **each
`osc.send` is very likely its own socket open, sendto and close** rather than a
write to a shared one. That was flagged as a suspect before the first hardware
test; the test — where the fix that helped was halving the datagram count, not
the byte count — is the evidence for it.

It is why the payload is packed in pairs, why the fps cap exists, and why the
first thing to try if the mirror costs more norns CPU than expected is dropping
`fps` in the mod menu. The structural fix, if it ever comes to that, is the
Path 2 capture in [05-prior-art.md](05-prior-art.md) — a native sender with one
socket of its own — which would not change a byte of this protocol.

### Geometry

128 × 64, one pixel to one pixel. The feature refuses anything else rather
than scale: `compose()` returns null unless `w == 128 && h == 64`. A scaled
one-bit UI is worse than no UI, and the panel is 128 × 64 anyway.

---

## What is deliberately *not* on the wire

- **No pixels from the panel to norns.** Upstream built `GET /api/frame`,
  shipped it and removed it the same day because polling it captured the render
  loop; the lesson is written into the firmware as a design rule. If the panel
  ever needs to appear on the norns screen, the poll-only
  `GET /api/patterns/<slug>?ext=thumb` exists and returns RGB565, and
  `screen.poke` would draw it — but at seconds per frame, not as a mirror.
- **No frame acknowledgements.** Nothing retransmits. The full refresh is the
  recovery mechanism, and it is unconditional, which means it cannot get stuck.
- **No audio lanes on the wire yet.** When they come they will not be a new OSC
  route: the panel's `fillInput` hook writes `knobAudioValue[]` directly. See
  [04-roadmap.md](04-roadmap.md).
