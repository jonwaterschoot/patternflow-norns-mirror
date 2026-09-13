# 05 — Prior art

Checked so we don't rebuild what exists. Short version: **nobody has built
norns → ESP panel**, but the norns-side capture is a solved problem we can
borrow from if the Lua one ever strains.

## `ndi-mod` — the established way to get the norns screen off the device

[`github.com/Dewb/ndi-mod`](https://github.com/Dewb/ndi-mod), vendored here at
`vendor/ndi-mod`. A norns system mod that shares the OLED over the network in
near-real-time with no script changes: about one frame of latency over Wi-Fi
and only 1–2% extra CPU.

It targets **NDI**, which is heavyweight video with zeroconf discovery. An
ESP32-S3 cannot realistically receive it, so ndi-mod cannot feed Patternflow as
it stands. Its value to us is twofold: it is proof that capturing the norns
screen continuously is cheap and reliable, and it is a ready fork base if our
pure-Lua capture ever needs replacing.

### How it captures, and why that matters to us

The mod is Lua plus a native `.so` loaded straight into matron's process
(`package.cpath … /lib/?.so`). Running *inside* matron is what lets it reach
matron's own Cairo surface:

```cpp
cairo_t*         ctx     = screen_context_get_primary();
cairo_surface_t* surface = cairo_get_target(ctx);
unsigned char*   data    = cairo_image_surface_get_data(surface); // ARGB32
memcpy(buffer, data, height * stride);
```

and the per-frame trigger is a Lua hook that wraps the redraw:

```lua
mod.hook.register("script_post_init", ..., function()
  local refresh = norns.script.refresh
  norns.script.refresh = function() ndi_mod.update(); refresh() end
end)
```

So the whole trick is: run inside matron, `memcpy` the Cairo surface on each
redraw. No re-rendering — that is why it is nearly free.

Our mod uses the same wrapping technique with two differences, both deliberate:

- We wrap **`Screen.update_default`**, not `norns.script.refresh`. The
  screensaver reassigns `Screen.update` on sleep and `Screen.ping` reassigns it
  back on wake, so a wrapper on `update` is silently discarded the first time
  the screen sleeps. `update_default` is the single funnel to
  `_norns.screen_update()` and survives both.
- We read through `screen.peek` from Lua instead of memcpying the surface from
  C, which costs more per frame and needs no toolchain at all.

## `norns.online`

schollz's community project: a script plus a site that beams the screen (as
video) and audio out, with remote control. It relays through an external
server, needs ffmpeg and mpv (~300 MB), and treats the screen as a video
stream. Not local, not lightweight, and the wrong shape for feeding an ESP.

## maiden

`norns.local` is the code editor and REPL. It does **not** show the screen.
There is no built-in screen mirror on norns.

---

## The capture decision this resolves

Both capture styles feed the *same* `screencast` feature over the *same*
datagrams, so this is a swappable half, not a fork in the road.

### Path 1 — pure-Lua `screen.peek` ★ what we built

`screen.peek(0,0,128,64)` returns the same 8192 pixels ndi-mod memcpys, just
marshalled through Lua.

- **+** No native build, no matron headers, no cross-toolchain. Editable on the
  device over SSH. Portable across norns and shield.
- **−** The peek, the encode and the send happen on the Lua thread each frame.

The two things that make it viable are in the mod: the per-pixel conversion is
a single `gsub` in C rather than a Lua loop, and unchanged bands of the screen
are not sent at all.

### Path 2 — fork ndi-mod's native capture

Rip out NDI, keep the scaffold, send our datagrams instead.

- **+** 1–2% CPU, proven, and you inherit the surface access, the per-frame
  hook and the buffer management.
- **−** Needs the norns build headers and a CMake build for the device.

### When to switch

If the Lua mirror measurably costs audio — dropouts, or a script that stutters
only while mirroring — Path 2 is the answer and the panel side does not change
by a line. Until then the toolchain-free version is worth more than the CPU it
saves.
