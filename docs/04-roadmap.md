# 04 — Roadmap

Reordered after the source review in [01-verified-facts.md](01-verified-facts.md).
The big change: **the panel controlling norns turns out to be the cheapest
thing here, not the dearest.** norns already answers `/remote/enc` and
`/remote/key`, and the panel already sends knob and button events, so that
milestone is a translation table and no firmware work at all. It now comes
first, because it is a working instrument on its own and it proves the link
before any of the harder parts.

Each milestone is independently useful and independently shippable.

---

## M0 — Link up ✅ *code written, not yet run on hardware*

Both devices on one Wi-Fi; the mod installed; the firmware flashed.

**Exit:** the mod menu shows `linked`, and `curl http://patternflow.local/api/status`
lists `screencast` in caps.

## M1 — The panel as a norns controller ✅ *code written, not yet run on hardware*

Panel encoders 1–3 and buttons 1–3 drive norns encoders and keys, system-wide,
under any script, with no script changes. Nothing but the mod is needed —
this milestone would work against **stock Audio-edition firmware**.

**Exit:** turning panel knob 2 moves the same thing norns encoder 2 moves.

## M2 — The mirror ✅ *code written, not yet run on hardware*

The norns screen on the panel, in 16 grey levels, no script changes.

**Exit:** any script's screen appears on the panel; the panel returns to its
pattern within a second of the mirror stopping.

## M3 — Hue ✅ *code written, not yet run on hardware*

Panel knob 4 tints the mirror; norns's grey survives as the value channel;
knob at home = plain white. Native Patternflow brightness stays the brightness
control.

**Exit:** a shaded, single-hue mirror whose colour you dial from the panel.

> M0–M3 are all implemented and tested offline (88 assertions, plus a firmware
> build whose composition is verified in the shipped bytes). What none of them
> have is a panel and a norns in the same room. That is the next real step, and
> [the install guide's bring-up section](00-install.md#part-3--bring-up) is
> written for it.

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

Nothing at present.

**Closed 2026-09-28:** one panel doubled a row pair under the mirror. It was
the panel; a replacement does not do it.
[06-row-ghosting.md](06-row-ghosting.md) keeps the diagnosis.

---

## Explicitly not planned

- **Pixels from the panel to norns.** Upstream removed `GET /api/frame` the day
  they shipped it. The thumb endpoint exists for stills; there is no live
  reverse mirror and there should not be.
- **A relay server or bridge webapp.** Both devices speak OSC natively and are
  on the same network. Anything in the middle is a moving part with no job.
- **Forking Patternflow.** Out-of-tree composition is upstream's documented
  path and it is CI-enforced. See [03-architecture.md](03-architecture.md).
