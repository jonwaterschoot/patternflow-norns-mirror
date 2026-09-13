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
/pf/scr       ,ffs   chunk, nchunks, payload
/pf/scr/ping  (no arguments)
```

`chunk` and `nchunks` are floats because **norns cannot send anything else**:
matron marshals every Lua number with `lo_message_add_float`. The panel-side
parser accepts `i` as well, so a desktop test rig can speak the same protocol
without a second code path.

### The payload

One hex character per pixel — `'0'`–`'9'`, `'a'`–`'f'` — for the norns grey
level 0–15, row-major from the top-left. With the mod's `nchunks = 8` each
chunk carries 1024 pixels, which is exactly 8 rows, and the datagram lands
around 1060 bytes: comfortably inside a 1500-byte MTU, no IP fragmentation.

Three properties worth stating, because each one bought something:

**Every datagram is complete and idempotent.** Chunk *c* covers pixels
`[c·px, (c+1)·px)` and says everything about them. There is no reassembly
buffer, no sequence number and no partial-frame state on the panel. A dropped
packet costs those rows until they next change or until the mod's two-second
full refresh comes round — it can never leave the panel showing half of one
frame and half of another.

**Only changed chunks are sent.** The mod keeps the last payload per chunk and
compares. A static norns screen sends nothing at all; typing in the parameter
menu sends one or two chunks. This is what makes one-character-per-pixel
affordable.

**Encoding is a single pass in C.** `screen.peek` hands back 8192 bytes and the
mod converts them with one `string.gsub(buf, ".", table)`. The per-pixel work
never enters the Lua interpreter, which is the whole reason a pure-Lua mirror
is viable at all.

### Why hex and not something denser

Packing two pixels into one byte would halve the traffic, and it was
considered. It needs at least 225 distinct byte values, which means the high
half of the range — and OSC defines a string as *non-null ASCII*, 7-bit. Both
ends here are ours, but the bytes travel through liblo, which is not. Given
that the dirty-chunk check already removes most real traffic, spec-clean beat
half-size. If the mirror ever needs the bandwidth, the honest fix is a
different address with a binary payload rather than a string that lies about
being ASCII.

### Liveness

`/pf/scr/ping` goes out four times a second whenever the mirror is on, whether
or not anything changed. Without it a static screen would look identical to a
disconnected norns, and the feature would hand the panel back to the running
pattern mid-session.

The panel treats the mirror as live for `PF_SCREENCAST_TIMEOUT_MS` (1200 ms)
after any packet — long enough to ride out a couple of lost keepalives.

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
