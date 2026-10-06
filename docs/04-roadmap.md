# 04 — Roadmap

Each milestone is independently useful and independently shippable. M0, M2
and M3 run on hardware today — firmware v0.4.0 on Patternflow core 3.11.0, and
the mod — and are stable. M1 is built but switched off. What hardware taught us
along the way is in [06-hardware-findings.md](06-hardware-findings.md).

---

## M0 — Link up ✅ *on hardware*

Both devices on one Wi-Fi; the mod installed; the firmware flashed.

**Exit:** the mod menu shows `linked`, and `curl http://patternflow.local/api/status`
lists `screencast` in caps.

## M1 — The panel as a norns controller ⏸ *switched off*

Panel encoders 1–3 and buttons 1–3 drive norns encoders and keys, system-wide,
under any script, with no script changes. Nothing but the mod is needed —
it would work against **stock Audio-edition firmware**.

Built, and on hardware it transferred badly, so the mod no longer acts on panel
events (`CONTROL_AVAILABLE` in `mod.lua`) whatever a saved config says. The
routing is kept and still tested. See
[below](#panel-knobs-driving-norns-off-until-understood).

**Exit:** turning panel knob 2 moves the same thing norns encoder 2 moves.

## M2 — The mirror ✅ *on hardware*

The norns screen on the panel, in all 16 grey levels, no script changes.

**Exit:** any script's screen appears on the panel; the panel returns to its
pattern within a second of the mirror stopping.

## M3 — Hue ✅ *on hardware*

Panel knob 4 tints the mirror; norns's grey survives as the value channel;
knob at home = plain white. Native Patternflow brightness stays the brightness
control.

**Exit:** a shaded, single-hue mirror whose colour you dial from the panel.

---

## M4 — Mixer page: show *and* control

The first genuinely bi-directional feature, and it is cleaner than mirroring
because it is not screen-scraping: the norns mixer is **not part of any
script**. Output, input, monitor, reverb and compressor levels are global
system params, and live meter data comes from built-in polls (`amp_in_l/r`,
`amp_out_l/r`). All of it is readable and settable whatever is loaded.

- **Show:** the mod reads the mix params and amplitude polls and sends them as
  small OSC messages; a panel-side page draws faders and VU meters in colour.
  Params a few times a second, meters faster.
- **Control:** panel encoders map to output / input / monitor / reverb, sent
  back either as `/param/<id>` (which norns already answers) or through the
  `audio.*` API from the mod.

**Exit:** the panel is a colour outboard mixer for norns that works under every
script.

## M5 — Sound-reactive

Patternflow patterns moving to norns's audio. **This needs no new OSC route**,
which is the correction the source review turned up: the "lanes" are
`knobAudioValue[]` in `InputFrame`, and a feature writes them from its
`fillInput` hook. The core then turns them into virtual knob deltas, so
*ordinary patterns react with no audio-specific code in them at all*.

- norns: an amplitude poll streamed to the panel.
- panel: our feature's `fillInput` writes lane 0 from it.
- Richer reactivity (bands, onsets) is a norns-side DSP question and does not
  change the transport.

**Exit:** an off-the-shelf Patternflow pattern visibly moves to norns's output.

## M6 — A dedicated piece

The co-render described in [03-architecture.md](03-architecture.md), Option 1:
a norns script that computes high-level state and a Patternflow pattern that
renders a colour scene from it — parameter-driven, lane-reactive, with the
panel's own encoders feeding back into the script and a grid or arc or MIDI
steering the whole thing.

By this point the transport, the fork-free build and the panel-side feature
workflow are all proven by the milestones above. This is the first one where
the interesting work is aesthetic rather than structural.

**Exit:** something you would show someone.

---

## Open, parked

### Grey levels: the wire is done, the look is not

The wire carries all 16 levels since firmware v0.4.0
([02-wire-protocol.md](02-wire-protocol.md#the-payload)), and the mirror is
stable. Anti-aliased shapes — circles, diagonals, soft edges — still look less
natural than on the OLED, because their dim edge pixels nearly vanish on the
LEDs ([why](06-hardware-findings.md#the-picture-is-close-not-identical)). The
current state is kept; if it is picked up again, cheapest first:

- **A per-level brightness table** in `buildPalette()` (`core_screencast.h`)
  in place of `v = lvl / 15`, lifting the low levels so they survive the
  driver's CIE1931 curve. Tune it by eye with the mod's `ramp` card held next
  to the OLED: every band should be distinguishable, in the same order.
- **Ordered dithering** on the panel, if the dimmest levels cannot be made
  distinct on their own.

### Panel knobs driving norns: off until understood

[M1](#m1--the-panel-as-a-norns-controller--switched-off) is off. The "norns
appears to hang" part was very likely the name-lookup freeze, since fixed
([findings](06-hardware-findings.md#norns-froze-with-the-mod-enabled--name-lookups)),
so it is worth a second try. Before turning it back on, check what is left:
lost or late OSC datagrams (each detent is two of them, `delta` and `clicks`);
the panel applying the same turn to its own pattern; matron's input path under
mirror load; an encoder acceleration mismatch. The handshake stays either way,
so the panel still knows where norns is and the menu still shows `linked`.

### Closed

In [06-hardware-findings.md](06-hardware-findings.md): a doubled row pair
(a faulty panel), patterns refused for memory (fixed upstream in core 3.10.5
and 3.11.0), and the norns freeze (fixed in the mod).

---

## Explicitly not planned

- **Pixels from the panel to norns.** Upstream removed `GET /api/frame` the day
  they shipped it. The thumb endpoint exists for stills; there is no live
  reverse mirror and there should not be.
- **A relay server or bridge webapp.** Both devices speak OSC natively and are
  on the same network. Anything in the middle is a moving part with no job.
- **Forking Patternflow.** Out-of-tree composition is upstream's documented
  path and it is CI-enforced. See [03-architecture.md](03-architecture.md).
