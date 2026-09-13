# norns ⇄ Patternflow bridge

**Load this file first to prime a coding session.** It's the map + the load‑bearing
decisions, so a fresh assistant doesn't re‑derive them. Read the linked docs for
depth. Project lives here; take it into VSCode and build with the Claude extension.

Linking a **shieldXL (monome norns)** and **Patternflow** (128×64 HUB75 RGB LED
matrix on an ESP32‑S3, 4 rotary encoders). Both screens are 128×64 — the reason
this pairing is natural.

## Current focus (in order)
1. **The mirror** — Patternflow shows the norns OLED, **monochrome**, no changes
   to any script. One expressive control: **hue/tint** on a panel encoder
   (Patternflow already has native brightness). ← primary goal
2. **Interaction** — make the panel a participant, not a photocopy: a **mixer
   page** the panel shows *and* controls while a script runs; a **sound‑reactive**
   link so patterns move to norns's audio.
3. **Tandem setup** — a reactive panel working with norns and its peripherals
   (grid / arc / MIDI / crow) as one instrument.

---

## Load‑bearing facts (don't re‑derive these)

- **Patternflow is a *parametric generative* panel, not a framebuffer display.**
  Its whole network surface (OSC / MIDI / HTTP / audio‑WebSocket / MQTT) drives
  **4 knobs / lanes / params + a pattern selector**; the panel generates its own
  pixels. Documented hard rule: *the device never streams pixels* (they built and
  removed `GET /api/frame`), and there's no host→device framebuffer endpoint.
- **Pushing pixels to the panel therefore needs a custom firmware *feature*.**
  Pattern modules (`.pfm`) can't — their ABI has no network. Features can (own a
  `WiFiUDP`, per‑frame draw hook). We fork Patternflow and add a `screencast`
  feature. Fork is expected and welcome here.
- **norns can read its own screen:** `screen.peek(0,0,128,64)` returns 8192 bytes,
  one per pixel valued 0–15. So the mirror's capture half can be a **pure‑Lua
  mod**, no norns fork. (Prior art `ndi-mod` does the same via a native Cairo
  memcpy at ~1–2% CPU — our Path 2 fallback if Lua strains. See doc 00.)
- **Transport is OSC over Wi‑Fi.** Both speak it natively. norns receives on
  **10111**; Patternflow (Audio edition) sends device→host on 9000, receives on
  9001. **Gotcha:** set `#define PF_OSC_REMOTE_PORT 10111` in `patternflow_secrets.h`
  so the panel talks to norns. Frames go on their **own** port (9002) — the OSC
  path caps at 256 bytes.
- **Where the animation lives (for later, co‑render work):** default to the
  visuals running **on the ESP**, driven by parameters — keeps norns free for
  audio, panel runs at native fps. Have norns steer exact pixels only when a
  script's whole point is exactness. (doc 08)
- **No one has built norns → ESP panel.** `ndi-mod` shares the screen but only as
  NDI video (not ESP‑friendly); `norns.online` mirrors via an external server +
  ffmpeg (heavy, not local); maiden shows no screen. (doc 00)

---

## File map

```
README.md            ← you are here (priming prompt)
docs/
  00-prior-art.md    ndi-mod / norns.online; how ndi-mod captures; Lua-peek vs fork
  01-findings.md     What each codebase exposes (the research)
  02-transports.md   Transport matrix; the OSC port-mismatch gotcha
  03-goal2-encoders-to-norns.md   Panel encoders → norns scripts (works today)
  04-goal1-norns-to-panel.md      Getting the norns screen onto the panel
  05-goal3-panel-to-norns.md      Rendering panel visuals on the norns screen
  06-iii-diii-and-the-bridge.md   Where the iii / grid / bridge-webapp work fits
  07-roadmap.md      Milestones M0–M5 (current focus order)
  08-architecture.md Mirror vs co-render; where the animation lives (ESP vs norns)
  09-interaction-expansions.md    Hue control; mixer show+control; sound-reactive; tandem
norns/
  patternflow.lua    Require-able lib: handshake + knob/button in, pattern/param out
  pf_monitor.lua     Demo script proving the link end to end
  mod/screenmirror/  The mirror MOD (screen.peek → pack → send), no script changes
patternflow-firmware/
  features/screencast/   The panel-side mirror feature (fork): receive frame + blit
bridge-webapp/
  README.md          Optional bridge (extend the diii emulator) for later work
```

## Prerequisites
- Both devices on the same Wi‑Fi.
- Patternflow on the **Audio edition** firmware (OSC + lanes). Check
  `curl http://patternflow.local/api/status` for `"osc"` in `caps`.
- norns: nothing special; OSC is built in, screen reachable as `norns.local`.

## Build order
M0 link‑up → M1 mono mirror → M2 hue → M3 mixer (show+control) → M4 sound‑reactive
→ M5 tandem. Details and exit criteria in `docs/07-roadmap.md`.

## Status of the code here
Starting points, written against the specs, **not hardware‑tested.** The norns
Lua (`patternflow.lua`, `pf_monitor.lua`, the mod) should run with minor tweaks;
the `screencast` feature is a design skeleton to reconcile against your firmware
tree. Two things to verify first: whether norns `osc.send` resolves `.local`
(else use the IP) and whether it passes real OSC blobs (else base64, as drafted).
