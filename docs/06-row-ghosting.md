# 06 — Closed: row ghosting on one panel

**Status: resolved 2026-09-28 — a faulty panel.** The panel was replaced, and
the new one does not show the fault under the same `line` card, firmware and
mod. Nothing in this project was changed to fix it, and nothing needed to be.
The diagnosis below was reached before the swap and is kept because it was
right, and because it is the route the next person with a doubled row should
take. See [the resolution](#resolution) for what the swap does and does not
tell us.

## The symptom

On one specific Patternflow unit, mirroring the norns screen shows a row
appearing twice. With the mod's `line` test card — a single lit row you move
with `line y`:

| `line y` | what the panel shows |
|---|---|
| 0 – 3 | one row, correct |
| 4 – 5 | **rows 4 and 5 both lit**, whichever of the two is selected |
| 7 and up | one row, correct |

The second row is **dimmer** than the selected one.

It does not happen with Patternflow's own patterns, and it is not present on
the device in any other use.

## What that rules out, conclusively

**It is not the data.** The `line` card contains exactly two values: level 15
on one row, level 0 on every other. There is no intermediate level anywhere in
the image. A row displaying an in-between brightness is therefore showing
something that is not in the data, and no duplication, shift or mis-chunk can
invent it. Whatever is happening, it happens after the pixels arrive.

(The panel's own check agrees from the other end: `/api/status` →
`screencast.rowdup` counts byte-identical adjacent row pairs in the buffer
about to be drawn. With the `rows` card up it must be 0. See
[the diagnostic section](00-install.md#diagnosing-a-display-fault).)

**It is not the dead pixel.** The unit has one dead LED in a corner. Row
addressing happens before any individual emitter is driven, so a dead emitter
cannot change which row's data is latched. A dead pixel is a hole in a fixed
place, never a repeat.

**It is not latch blanking.** This was the first hypothesis and the obvious
one: latch blanking is the HUB75 driver's standard control for row-to-row
bleed, and `src/core_display.h` hardcodes it to 2 against a library maximum of
4. **Tried at 3 and at 4 — no change at all.** That is a real result and it
argues against ordinary ghosting, because latch blanking is precisely the knob
that fixes ordinary ghosting.

**It is not general ghosting of any kind.** Bleed caused by timing would affect
every high-contrast row boundary, not one pair. Rows 0–3 and 7+ are clean under
the same content at the same brightness.

## Why it only shows through the mirror

Patternflow's patterns are smooth colour fields: neighbouring rows are nearly
the same, so a faint copy of one inside the other cannot be seen. A one-pixel
white line on black is the highest-contrast content a 128 × 64 panel can be
asked to show, and a mirrored norns UI is almost nothing else. The fault was
always there; the panel had simply never been shown content that could reveal
it.

This is worth remembering in general: **the mirror is a much harsher test of a
panel than the patterns it was built for.**

## Where that leaves it

A fault anchored to one adjacent row pair, unaffected by the timing control
that governs bleed, is most consistent with the **row-select path for those
specific lines**: a shift-register stage or line-driver channel that partially
enables its neighbour. On a 1/32-scan 128 × 64 panel, rows 4 and 5 are
addresses `00100` and `00101` — one bit apart — but a simple address-line fault
would affect every even/odd pair, and it does not. That points at one bad
channel rather than a shared signal.

Unit-specific, and the unit already has one dead LED, so a slightly
out-of-spec panel is a coherent story.

## Resolution

Swapping the panel made the fault disappear, and that confirms the conclusion
above: the fault was in that unit, not in the mirror, the mod, the firmware or
the driver settings. The swap kept everything else the same, so it is the one
test that separates the panel from everything upstream of it.

It does not say *which* part of the old panel was at fault. The row-select
explanation is still the most likely one, but the old panel is the only way to
check it. The brightness and ribbon tests below were never run on it. Nothing
was reported upstream, because nothing upstream was at fault.

## If you see this on another panel

The steps below were the plan before the swap. **If a spare panel is
available, try it first.** It settles the question in one step, which is how
this case was closed. Otherwise, roughly in order of effort:

1. **Does it depend on brightness?** `curl "http://patternflow.local/api/display?brightness=30"`
   and again at 200, with the `line` card up. A ghost that scales with drive is
   timing or charge; one that is present at every level is more likely a hard
   fault in that channel.
2. **Does it survive a different ribbon?** Shorter, reseated, or a spare. A
   ferrite on it. This is the cheapest real test and `core_display.h` recommends
   the same order for a different artefact.
3. **Lower the panel clock.** `src/core_display.h` sets
   `mxconfig.i2sspeed = HZ_15M` with `min_refresh_rate = 240`, and its own
   comment discusses dropping to 8 MHz for artefacts — **lower
   `min_refresh_rate` with it**, as that comment says. Since v3.10.4 the
   vendored driver meets the refresh floor by switching to a dimmer timing
   pattern, not by dropping colour depth (`src/hub75/VENDORED.md`). A lower
   clock with the floor left at 240 makes the panel dimmer rather than
   banded. Before v3.10.4 it dropped colour depth instead, and gradients
   banded. Same edit-and-revert loop as latch blanking.
4. **Confirm it is independent of this project.** Anything that puts a single
   lit row on the panel without the mirror does it — a one-off pattern module,
   or the Live Editor. If a hand-written pattern drawing `drawFastHLine(0, 4,
   128)` on black also doubles, that is the end of the question and it belongs
   upstream or with the panel.
5. **Then report it.** With 1–4 done it is a good issue for
   [engmung/Patternflow](https://github.com/engmung/Patternflow): a reproducible
   row-pair artefact, latch blanking ruled out, and a note that mirroring a
   1-bit UI is a stress case the firmware has not had to face before.

## Trying a core setting locally

`latch_blanking` and `i2sspeed` both live in `src/core_display.h`, which is a
**core file** — nothing in this project will change it for you, and neither is
an `#ifndef` the bundle could override. To experiment:

```bash
vi vendor/patternflow/firmware/patternflow/src/core_display.h
tools/build-firmware.sh
# ... test, then put it back:
git -C vendor/patternflow checkout src/core_display.h
```

`git -C vendor/patternflow status` should be empty again afterwards. Leaving it
dirty is what makes taking an upstream update stop being a clean checkout.

---

## Not to be confused with

**Banded tearing**, where a frame visibly filled in from the top, was a
different fault with a different cause — chunks were applied as they arrived
rather than on a frame boundary. Fixed by double-buffering behind
`/pf/scr/end`; see [02-wire-protocol.md](02-wire-protocol.md#pfscrend--frame-complete).
If something that looks like row duplication appears *while content is moving*
and settles when it stops, suspect that rather than this.
