# 08 — Architecture: mirror vs co-render, and where the animation lives

Two things that look similar but are built oppositely. Keep them separate.

## Feature A — the mirror (generic, dumb, monochrome)
Any script's 1‑bit OLED appears on the panel, no script changes. This is a
utility: it can never be *richer* than the OLED, because it's a photocopy.
- norns: a **mod** wraps `screen.update`, reads the framebuffer with the stock
  `screen.peek(0,0,128,64)` (one byte 0–15 per pixel), packs it, sends it.
- Patternflow: a **screencast feature** on your fork receives frames and blits.
- Built in `norns/mod/screenmirror/` + `patternflow-firmware/features/screencast/`.

## Feature B — co-rendering (expressive, colored) — the landscape vision
norns is the **brain**; it sends *meaning*, not pixels; Patternflow renders a
lush colored interpretation. Not mirroring. This is where "more detailed than
the 8×16 grid" lives. It needs a **dedicated norns script** and **dedicated
Patternflow visuals** — the subject of step 2.

## The triangle (what gives your grid link a purpose)
```
colored grid (neotrellis / iii)  →  norns (brain: logic, timing, state)  →  Patternflow (color render)
        hands / control                     single source of truth              expressive eyes
```
Your color‑grid interface craft (palettes, RGB layout) is the *look* language;
norns holds the state; the grid steers. The link needn't be MIDI.

---

## THE decision for step 2: does the animation run on the ESP or on norns?

Framed as one question: **must the panel show *exactly* what norns computed, or
an *interpretation* of it?**

### Option 1 — visuals run on the ESP, norns sends parameters ★ default
The animation logic is a Patternflow pattern/feature; norns sends a compact set
of values that steer it.
- **Pros:** norns stays free for audio (it's running SuperCollider — rendering a
  rich animation it can't even display is wasteful and risks dropouts); the panel
  runs at its native 40–55 fps regardless of Wi‑Fi jitter; plays to the ESP's
  whole reason for existing (shader‑style generative color).
- **Cons:** logic is split across two languages (Lua brain + C++/JS look); exact
  state (every leaf position) is hard to push through a few parameters — you
  either go *procedural* (the ESP invents its own leaves from mood values) or
  widen the channel on your fork.
- **"Parameters" isn't capped at 4.** Stock patterns read 4, but on your fork you
  can define a richer OSC vocabulary and feed it in. So Option 1 spans from
  "4 mood knobs" to "a structured state packet."

### Option 2 — norns steers the full animation, the panel is a thin renderer
norns computes exact element state (leaf x/y/age, water level, which tracks
fired) and a Patternflow feature draws those exact elements in color.
- **Pros:** single source of truth, one language; perfect sync; every leaf on the
  panel is a real event.
- **Cons:** norns does the work (CPU, and it's rendering "blind" — it can't show
  color); higher bandwidth; underuses the panel's generative horsepower.
- (A degenerate version — norns renders a full RGB framebuffer and ships pixels —
  is Feature A in color, and best avoided: norns can't preview what it's drawing.)

### Recommendation
**Start Option 1, procedural.** For the first dedicated script (a landscape /
mood piece), norns computes high‑level state — `season, density, wind, water,
energy` — and a Patternflow pattern generates the color scene from it. Smallest
step that produces something beautiful, no ABI fork, validates the whole chain,
keeps norns free.

**Graduate to Option 2 (rich‑state renderer feature) only when a script's whole
point is exactness** — where each on‑screen element *is* a specific event whose
position carries meaning. That's the "custom environment" phase, and by then
you'll have the transport and fork workflow proven by the mirror.

Rule of thumb: **mood → ESP procedural. Meaning‑exact → norns steers.**
