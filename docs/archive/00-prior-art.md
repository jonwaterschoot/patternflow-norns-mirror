# 00 — Prior art, and how norns screen‑sharing actually works

Checked before building, so we don't reinvent what exists.

## Is there already a mod that shares the norns screen? Yes — `ndi-mod`
`github.com/Dewb/ndi-mod` is a norns **system mod** that shares the OLED over the
network in near‑real‑time, no script changes. ~1 frame of latency over Wi‑Fi,
only ~1–2% extra CPU. It's the established answer in the community for "get the
norns screen off the device."

It targets **NDI** (a video protocol for OBS / Resolume / Max / TouchDesigner).
NDI is heavyweight video with zeroconf discovery — an ESP32‑S3 can't realistically
receive it — so ndi-mod won't feed Patternflow as‑is. Its value is (a) proof the
capture is cheap and reliable, and (b) a ready **fork base** for our capture half.

## Is there a native mode that mirrors to a webapp? No
- `norns.local` (**maiden**) is the code editor / REPL. It does **not** show the
  screen.
- The only "screen in a browser" option is a community project, **`norns.online`**
  (schollz): a script + site that beams screen (as video) + audio out and offers
  remote control. But it relays through an external server, needs ffmpeg + mpv
  (~300 MB), and treats the screen as a video stream. Not local, not lightweight,
  wrong shape for us.

Bottom line: nobody has built norns → ESP32 panel. The bridge is still ours to
make — but the norns‑side *capture* is a solved problem we can borrow.

---

## How ndi-mod captures the screen (the mechanism, dissected)
The mod is Lua **plus a native `.so`** (`src/ndi_mod.cpp`) loaded straight into
matron's process (`package.cpath … /lib/?.so`). Because it runs *inside* matron
it reaches matron's own Cairo screen surface directly:

```cpp
cairo_t*         ctx     = screen_context_get_primary();
cairo_surface_t* surface = cairo_get_target(ctx);
unsigned char*   data    = cairo_image_surface_get_data(surface); // ARGB32
memcpy(buffer, data, height * stride);                            // that's it
```

Per‑frame trigger is a Lua hook that wraps the redraw:
```lua
mod.hook.register("script_post_init", ..., function()
  local refresh = norns.script.refresh
  norns.script.refresh = function() ndi_mod.update(); refresh() end
end)
-- (and it hooks screen.update() the same way)
```

So the whole trick is: **run inside matron, memcpy the Cairo surface on each
redraw.** No re‑rendering — that's why it's ~1–2% CPU. It grabs full ARGB at
full res; for us the norns UI is monochrome, so a mono/grey mirror loses nothing.

---

## The decision this resolves: how to capture on the norns side
Both capture styles feed the **same** Patternflow `screencast` feature over the
**same** UDP frame — only the norns half differs. So we can start simple and swap
later without touching the panel.

### Path 1 — pure‑Lua `screen.peek` mod  ★ start here
`screen.peek(0,0,128,64)` returns 8192 bytes (one per pixel, 0–15) — it reads the
*same* Cairo surface ndi-mod memcpys, just marshalled through Lua.
- **+** No native build, no matron headers, no toolchain. Pure Lua, trivial to
  iterate on with the Claude extension. Portable across norns/shield.
- **−** Peek + pack + encode happen on the Lua thread each frame; not free.
  Fine for a throttled 128×64 mono mirror; may glitch if pushed hard.

### Path 2 — fork ndi-mod's native capture
Fork ndi-mod, rip out NDI, drop in a small UDP sender to the screencast feature.
- **+** ~1–2% CPU, near‑real‑time, proven; you inherit the mod scaffold, the
  direct surface access, the per‑frame hook, and buffer management.
- **−** Needs the norns build headers (`hardware/screen.h`, cairo), a CMake build
  on/for norns. More setup; heavier to iterate.

### Recommendation
**Start Path 1** for the mono mirror — fastest to a lit panel, no toolchain.
**Graduate to Path 2** if CPU/latency/glitching bites, or when the mirror needs
to run rock‑solid alongside audio. Because the wire format is identical, this is
a drop‑in swap of the capture half, not a redesign.
