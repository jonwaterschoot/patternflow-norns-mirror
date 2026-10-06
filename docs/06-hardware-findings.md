# 06 — What the hardware taught us

What turned up once a panel and a norns were in the same room, in the order
it was found. Each entry is closed or parked; what is still open lives in
[the roadmap](04-roadmap.md#open-parked). The full investigations were longer
than their conclusions, and what is left here is the conclusion plus what to do
if it comes back.

---

## A row pair doubled on one panel — the panel

**2026-09-28. Closed: a faulty panel; a replacement does not do it.**

With the `line` card up, rows 4 and 5 lit together, the second one dimmer.
Nowhere else on the panel, and never under Patternflow's own patterns.

What settled it before the swap: the `line` card is level 15 on one row and 0
everywhere else, so a *dimmer* second row is showing a brightness that is not
in the data. No duplication or mis-chunking can invent it; it happens after
the pixels arrive. `screencast.rowdup` (0 with the `rows` card up) agreed from
the panel's side. Raising the driver's latch blanking from 2 to 3 and 4 —
the standard remedy for row bleed — changed nothing, and timing bleed would
have hit every high-contrast row, not one pair. That points at one row-select
channel in that unit.

Why only the mirror showed it: patterns are smooth colour fields, so a faint
copy of a row inside its neighbour cannot be seen. A one-pixel white line on
black is the worst case a panel can be asked to show, and a norns UI is little
else. **The mirror is a harsher test of a panel than the patterns are.**

If it happens on another panel: try a spare panel first — that is what closed
this one. Then [the test cards](00-install.md#diagnosing-a-display-fault) and
`rowdup` to separate the data from the drawing. `latch_blanking` and
`i2sspeed` are in `src/core_display.h`, a core file: edit it in the submodule
to experiment, then `git -C vendor/patternflow checkout src/core_display.h`.

## Some patterns would not load — fixed upstream

**2026-09-28, fixed by core 3.10.5 / 3.11.0 (firmware v0.3.0 and later).**

Community patterns such as moonwell (10.5 KB of code) and midnight clocktower
(14.1 KB) failed with `code N B needs M free, have K`. Before 3.10.5 a
pattern's code had to live in internal RAM, with 24 KB kept back for Wi-Fi and
HTTP, and the stock Audio edition's features left too little: measured with a
preset running, internal free was ~69.6 KB on Core, ~30.8 KB on Audio and
~28.5 KB on ours. The mirror cost ~2.3 KB of that; the Audio features ~39 KB.
The stock Audio edition refused the same patterns, so it was never this
project's doing. Rebooting into a pattern "worked" only because the pattern
was restored before the network started, which left Wi-Fi running under its
reserve.

Upstream then moved pattern code (3.10.5) and data (3.11.0) to PSRAM, and a
pattern's size no longer decides whether it loads.
[01-verified-facts.md](01-verified-facts.md#where-a-pattern-module-lives--and-why-its-size-stopped-mattering)
has the mechanism and the `/api/status` fields. No refusal has been seen since
the update; the patterns were not re-measured one by one.

If it comes back: `moduleMemory.codePolicy` in `/api/status` should read `2`.
`0` means this board failed the PSRAM read-back and is on the old rule — an
upstream report, with the board.

## norns froze with the mod enabled — name lookups

**2026-10-05. Fixed in the mod.**

Screen, encoders and menus all stopped, and stayed stopped until the mod was
removed. matron resolves the destination host name again on every `osc.send`,
on the Lua thread, and nothing caches it. While `patternflow.local` resolved
that cost nothing; when it stopped resolving — the panel rebooting into new
firmware — each lookup took seconds to fail (6.7 s, measured from a desktop on
the same network), and the mirror sends several messages a second.

The mod now looks the name up once, in a child process, sends nothing until it
has an IP, and then follows the source address of the panel's own packets.
[01-verified-facts.md](01-verified-facts.md#osc-on-norns) has the source;
[recovering a frozen norns](00-install.md#recovering-a-frozen-norns) has the
way out for a mod older than the fix. This is very likely also the "hang" that
was first blamed on the knobs, below.

## Panel knobs driving norns — off for now

**2026-10-04. Parked.**

Turns transferred badly, and norns at times appeared to hang or to fight the
panel for input. Control was switched off in the mod so the work could focus on
the mirror (`CONTROL_AVAILABLE` in `mod.lua`; the routing is kept and tested).
The freeze above was found a day later and fits the "hang" part; the rest has
not been looked at. [The roadmap](04-roadmap.md#panel-knobs-driving-norns-off-until-understood)
lists what to check before turning it back on.

## The picture is close, not identical

**2026-10-06. Parked; the current state is kept.**

With 16 levels on the wire (firmware v0.4.0) the mirror is stable, but shapes
like circles look less natural on the panel than on the OLED. norns draws with
anti-aliasing: a curve's edge is a run of dim, partly-covered grey pixels,
which the OLED's tiny, tightly packed pixels blend into a smooth line. On the
panel those levels go through our linear palette and then the HUB75 driver's
CIE1931 brightness curve (effective exponent ~2.44; upstream measured an input
of 64 of 255 — about our level 4 — lighting at 4.4 %, `config.h`). The dim
edge pixels nearly vanish, and each LED is a bright point with dark space
around it, so the edge reads as steps. What is left to try is in
[the roadmap](04-roadmap.md#grey-levels-the-wire-is-done-the-look-is-not).
