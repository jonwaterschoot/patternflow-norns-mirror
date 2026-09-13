# 09 — Beyond the mirror: interaction expansions

The mirror is a one‑way photocopy. These are the steps that make the panel a
*participant*. Ordered roughly by effort. Each is independent.

---

## The mirror's one control: hue (primary feature, not an expansion)
The mirror is monochrome, but should have a single expressive knob: **hue/tint**.
- Patternflow already has a **native global brightness** control (K1 long‑press),
  so we don't rebuild that.
- The `screencast` feature renders each incoming pixel as `HSV(hue, 1, value)`
  where `value` is the norns grey level. Map **one physical Patternflow encoder →
  hue**. Turn it and the whole mirror shifts color; norns's own grey shading
  survives as brightness within that hue.
- This wants the mirror to carry grey, not just on/off: send **4bpp** (levels
  0–15) rather than 1bpp so the hue is shaded, not flat. Start 1bpp/flat‑hue to
  prove the pipe, then move to 4bpp (needs frame chunking — see the mod/feature
  READMEs) for shaded hue.

---

## Expansion A — a mixer page: show *and* control, alongside any script
**Question: can the panel display and control the norns mixer while a script
runs? Yes — and it's cleaner than mirroring.**

Why it works: the mixer isn't part of any script. Output/input/monitor/reverb/
comp levels are **global system params**, and live meter data is available from
built‑in **polls** (`amp_in_l/r`, `amp_out_l/r`). All of it is readable and
settable independently of whatever script is loaded. So this is not screen‑scrape
— it's a dedicated semantic UI built from data:

- **Show:** the mod/script reads the mix params + amplitude polls and sends them
  (small OSC messages) to a Patternflow pattern/feature that draws faders + VU
  meters in color. Updates a few times a second; meters faster.
- **Control:** map the panel's 4 encoders → output / input / monitor / reverb
  (or comp) levels, sent back as OSC `/param/<id>` or the norns `audio.*` API.
  No script cooperation needed; the params are global.

This is the first genuinely **bi‑directional, no‑script‑changes** feature: the
panel becomes a color outboard mixer for norns that works under every script.

---

## Expansion B — sound‑reactive: patterns that move to norns's audio
Patternflow's **Audio edition** already has the reactive channel built in: **4
"lanes" (0..1)** that patterns read, normally fed by the audio WebSocket (port
81) or the onboard mic. We just need to feed those lanes from norns's audio.

Transport choice (norns Lua has OSC, not a WebSocket client):
- **Recommended (small fork addition):** on your Patternflow fork, add an OSC
  route `/pf/lane/N <0..1>` that writes lane N. Then norns polls its output
  amplitude and sends `/pf/lane/0 <amp>`. Any lane‑reading pattern is instantly
  norns‑reactive, no bridge, no WebSocket.
- **No‑fork alternative:** the bridge webapp subscribes to norns amplitude (OSC)
  and forwards to the panel's existing audio WebSocket. Uses stock Patternflow,
  adds a moving part.

**How to make a pattern react to norns sound** (the instruction you asked for):
in the pattern, read `lanes[]` from the `InputFrame` and drive whatever you like
(size, speed, brightness, spawn rate) from `lanes[0]`. On norns, start an
amplitude poll and stream it to lane 0. Richer reactivity (frequency bands,
onsets) = a norns DSP/engine extracting features → more lanes, same transport.

---

## Expansion C — the tandem setup (where this is all heading)
A reactive Patternflow panel working with norns **and its peripherals** as one
instrument:
```
grid / arc / MIDI / crow  →  norns (brain: state, timing, audio)  →  Patternflow
     hands / control              single source of truth               color eyes
```
- Any norns controller (a color grid, arc, MIDI, crow) steers a norns script.
- norns holds the state and the sound.
- Patternflow renders a rich colored view that's also **audio‑reactive** (lanes)
  and **parameter‑driven** (Expansion A/B transport), and its encoders feed back
  into the script.

At that point the pieces from the earlier docs combine: parametric co‑render
(doc 08), the lane/param transport (here), and the mixer‑style semantic UI. The
mirror was the warm‑up that proved capture + transport + a panel‑side feature;
everything here reuses that spine.
