# 03 — Architecture

Two things here look similar and are built oppositely. Keeping them apart is
most of the design.

## Feature A — the mirror

Any script's screen appears on the panel, unchanged, with no cooperation from
the script. It is a utility, and by construction it can never be *richer* than
the norns OLED, because it is a photocopy of it.

- **norns:** a system mod wraps the redraw, reads the framebuffer with
  `screen.peek`, and sends changed bands of rows.
- **panel:** the `screencast` feature receives them and returns them from
  `composeFrame`.
- One expressive control, panel-side: **hue**. The norns grey level becomes the
  value channel of an HSV colour whose hue a panel encoder sets. Patternflow
  already owns global brightness (K1 long-press), so the mirror does not
  rebuild it.

Built in [`src/norns/mod/pf-mirror/`](../src/norns/mod/pf-mirror/) and
[`src/patternflow/features/screencast/`](../src/patternflow/features/screencast/).

## Feature B — co-rendering

norns is the brain and sends *meaning*, not pixels; the panel renders a
coloured interpretation of it. This is not mirroring, and it is where anything
genuinely richer than the OLED has to live. It needs a dedicated norns script
*and* dedicated panel visuals — the two halves are designed together or not at
all.

```
grid / arc / MIDI / crow  →  norns  →  Patternflow
     hands, control      state, timing,   colour, and
                              sound        its own knobs
```

---

## The decision that governs Feature B

One question decides it: **must the panel show exactly what norns computed, or
an interpretation of it?**

### Option 1 — the visuals run on the ESP, norns sends parameters ★ default

The animation is a Patternflow pattern; norns sends a compact set of values
that steer it.

- norns stays free for audio. It is running SuperCollider, and having it render
  a rich animation it cannot even display is both wasteful and a dropout risk.
- The panel runs at its native frame rate regardless of Wi-Fi jitter.
- It plays to what the ESP is for.

The cost is that the logic is split across two languages, and exact state
(every element's position) is hard to push through a few values — you either
go procedural, where the panel invents its own detail from mood values, or you
widen the channel.

"Parameters" is not capped at four. Stock patterns read four knobs, but the
`fillInput` hook can drive those from anything, and a feature of ours can carry
a richer vocabulary. Option 1 therefore spans everything from four mood knobs
to a structured state packet.

### Option 2 — norns steers, the panel is a thin renderer

norns computes exact element state and a panel feature draws those exact
elements.

- Single source of truth, one language, perfect sync, every element on the
  panel a real event.
- But norns does the work, and it is rendering blind — it cannot preview what
  it is drawing. Bandwidth is higher and the panel's generative horsepower goes
  unused.

The degenerate version of Option 2 — norns rendering a full RGB framebuffer and
shipping pixels — is Feature A in colour, and is the one shape to avoid: all of
the cost, none of the benefit, and norns still cannot see what it made.

### The rule

**Mood → the ESP, procedurally. Meaning-exact → norns steers.**

Start with Option 1. Have norns compute high-level state — season, density,
wind, water, energy — and let a pattern generate the scene. It is the smallest
step that produces something worth looking at, it validates the whole chain,
and it keeps norns free. Graduate to Option 2 only when a script's whole point
is exactness, where each element *is* a specific event whose position carries
meaning.

---

## Why the panel side is a feature, and why we don't fork

A **pattern module** gets the framebuffer, `millis()`, RNG, maths and the
four-input `InputFrame`. It has no sockets, so it cannot receive anything from
the network. That rules patterns out for the mirror.

A **feature** gets `onNetwork()` to start services, a per-frame hook, and
`composeFrame` to put pixels on the panel. It can own a `WiFiUDP`. That is the
correct home.

And a feature does not require a fork. Upstream documents an out-of-tree
composition — your features and your two composition files are *copied over* a
checkout of core rather than merged into it — and enforces the boundary in CI.
So the core is a pristine submodule here, our diff against upstream is empty,
and taking an update is a `git checkout` in `vendor/patternflow` with nothing
to resolve. `tools/build-firmware.sh` is that recipe, and it runs upstream's
own boundary checker every build.

## Why the norns side is a mod, and why it is plain Lua

`screen.peek` is stock, so reading the framebuffer needs no fork and no native
build. `_norns.enc` / `_norns.key` are stock, so driving norns from outside
needs no script cooperation. Everything the bridge does on the norns side is
therefore reachable from Lua, which means it is editable on the device, over
SSH, with no toolchain — which matters more than the CPU it costs.

The CPU it costs is also small, because the one expensive thing — touching 8192
bytes per frame — is done with a single `gsub` in C rather than a Lua loop, and
because unchanged bands of the screen are not sent at all.

If that ever stops being true, the fallback is known and does not change the
protocol: fork [ndi-mod](05-prior-art.md)'s native Cairo capture, which runs
inside matron at 1–2% CPU, and have it send the same datagrams. The panel would
not know the difference.
