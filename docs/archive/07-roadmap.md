# 07 — Roadmap

Reordered around the current focus: **get the monochrome mirror (with a hue
control) working first**, then make the panel interactive. Each milestone is
independently useful.

## M0 — Link up (½ day)
- Both devices on one Wi‑Fi. Flash Patternflow **Audio edition**.
- `patternflow_secrets.h`: `#define PF_OSC_REMOTE_PORT 10111`.
- Confirm `curl http://patternflow.local/api/status` shows `"osc"` in `caps`.
- Run `norns/pf_monitor.lua`; confirm knob/heartbeat traffic both ways.

## M1 — The mirror, monochrome (1–2 days) ← **primary goal**
- norns: the `screenmirror` mod (Path 1, `screen.peek`) → 1bpp frames.
- Patternflow: the `screencast` feature receives + blits.
- **Exit:** any norns script's screen appears on the panel, no script changes.

## M2 — The mirror's hue control (½–1 day)
- Move the mirror to **4bpp** (grey 0–15, chunked frames) so shading survives.
- `screencast` feature renders `HSV(hue, 1, value)`; map one panel encoder → hue.
- Native Patternflow brightness stays as the brightness control.
- **Exit:** a shaded, single‑hue mirror whose color you dial from the panel.

*(Decision point: if the Lua mirror strains CPU or glitches, swap the capture
half for a fork of ndi-mod — Path 2 in doc 00. Panel side is unchanged.)*

## M3 — Mixer page: show + control (2–3 days) ← first bi‑directional feature
- Read global mix params + amplitude polls; send to the panel; draw faders/VU.
- Map the panel's 4 encoders → output/input/monitor/reverb levels (OSC/`audio.*`).
- Works under any running script (mixer is global, not per‑script).
- **Exit:** the panel is a color outboard mixer for norns.

## M4 — Sound‑reactive lanes (1–2 days)
- Fork: add OSC `/pf/lane/N <0..1>` → writes Patternflow lane N.
- norns: amplitude poll → stream to lane 0.
- Document the pattern‑side recipe (read `lanes[]`).
- **Exit:** Patternflow patterns visibly move to norns's audio.

## M5 — Tandem setup (open‑ended)
- Combine: a dedicated norns script + a Patternflow pattern that is both
  parameter‑driven and lane‑reactive, with the panel's encoders feeding back and
  a norns controller (grid/arc/MIDI/crow) steering. See docs 08 and 09.

---

### First session with the Claude extension
1. Open this folder in VSCode; load `README.md` as the priming prompt.
2. Stand up M0/M1: drop the mod in `~/dust/code/screenmirror/`, set the host,
   build the `screencast` feature on your Patternflow fork, and get one frame
   across.
3. Then M2 (hue) before moving to interaction.
