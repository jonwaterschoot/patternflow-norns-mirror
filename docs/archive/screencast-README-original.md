# feature: screencast (Feature A — the norns screen mirror)

The panel end of the **screen mirror**. Receives 1bpp 128×64 frames from the
norns `screenmirror` mod and blits them. This is the *only* correct place for
host→device pixels: a pattern module can't (its ABI has no network), and the
OSC/HTTP surfaces refuse per‑frame pixel data by design — so it's a **feature**
on your fork. Pairs with `norns/mod/screenmirror/`.

> Status: **not built.** This is a design + skeleton to develop from. It follows
> the feature contract in `firmware/patternflow/features/pf_feature.h` and mirrors
> the OSC feature (`features/osc/`), which is the closest existing template
> (UDP socket + per‑frame work + composes without touching core files).

## Why a feature, not a pattern
- A pattern gets: framebuffer pointer, `millis()`, RNG, math/noise, the 4‑input
  `InputFrame`. **No sockets.** So it can't receive frames.
- A feature gets: `onNetwork()` to start network services, a per‑frame hook, and
  `PFFeatureFrame` (dt, running, `chromeVisible`, patternName…). It can own a
  `WiFiUDP` and draw. → correct home for this.

## Wire protocol (matches the `screenmirror` mod)
The norns mod sends via `osc.send` (the only transport norns Lua has), so the
frame arrives as an OSC message on this feature's own port — **not** the OSC
feature's 9001 (its 256‑byte buffer can't hold a frame).

- Port: **9002** (`PF_SCREENCAST_PORT`).
- One datagram, OSC:
  ```
  address  /n/s
  typetag  ,is
  args     int32 seq        (drop stale by seq)
           string b64       (base64 of a 1bpp 128×64 frame = 1024 bytes,
                             row-major, MSB = leftmost pixel)
  ```
- base64 keeps the payload null‑free (OSC strings can't carry raw nulls) and
  fits one UDP packet (~1368 chars < MTU). The skeleton includes a small base64
  decoder and a tolerant OSC parser.
- **4bpp grey** upgrade later: 4096 bytes → chunk across datagrams, reassemble by
  seq; maps norns's 16 levels straight to white intensity on the RGB panel.
- If norns turns out to send real OSC **blobs** from Lua, switch the string arg
  to a blob and skip base64.

## Draw semantics
- Keep the latest decoded frame in a PSRAM buffer.
- The feature becomes "active" while frames arrive (e.g. within the last 500 ms);
  idle → yield the panel back to the running pattern.
- In the per‑frame hook, when active **and** `!chromeVisible` (don't paint over
  the device's own UI), blit: set pixel `(x,y)` on → white (or a configurable
  tint); off → black. For 4‑bit grey, map level → intensity.
- Respect the frame rule: the hook **must not block** — decode is O(1024), just
  a copy; no waiting on the socket inside the draw hook. Poll the socket in the
  network‑serviced path / `onFrame` drain, exactly like the OSC feature drains
  up to N datagrams per frame.

## Compose it in (no core edits)
1. `#define PF_SCREENCAST_ENABLED 1` and `PF_SCREENCAST_PORT 9002` (guarded).
2. Add `cap` string `"screencast"` so hosts can probe `/api/status`.
3. Register the feature in `features/features.h` (one line — that's the whole
   point of the feature system; your diff stays additive and `git merge upstream`
   stays clean).

## Hue control (the mirror's one knob)
The mirror is monochrome but tintable. Render each incoming pixel as
`HSV(hue, 1, value)` where `value` is the norns grey level (0–15), and map **one
physical panel encoder → hue**. Native Patternflow brightness stays the
brightness control; don't rebuild it. This wants **4bpp** frames (grey survives
as the value channel) rather than flat 1bpp — start 1bpp to prove the pipe, then
move to 4bpp (chunked frames) for a shaded, single‑hue mirror.

## norns side
See `docs/04-goal1-norns-to-panel.md` → Option B. The honest cost is on norns:
there's no Lua API to read its own framebuffer, so either the script maintains
its own byte buffer and UDP‑sends it, or you write a matron/mod Cairo tap to
capture arbitrary content.
