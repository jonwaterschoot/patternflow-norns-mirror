# norns ⇄ Patternflow

A bridge between a **monome norns** (built here against a denki-oto okyeren
shield-XL, but nothing in it is shield-specific) and **[Patternflow](https://github.com/engmung/Patternflow)**,
an open-source LED synthesiser: a 128 × 64 HUB75 RGB matrix on an ESP32-S3 with
four push-encoders.

Both screens are 128 × 64. That is the coincidence the whole project stands on
— a norns frame maps to the panel one pixel to one pixel, with no scaling.

Three things work, in increasing order of ambition:

1. **The panel drives norns.** Its encoders and buttons act as norns encoders
   and keys, system-wide, under any script, with no script changes.
2. **The panel mirrors the norns screen**, in 16 grey levels, tinted to any hue
   from a panel knob.
3. **Later: the two co-render** — norns as the brain sending meaning rather
   than pixels, and the panel rendering it in colour. See
   [docs/03-architecture.md](docs/03-architecture.md).

> **Status: written and tested offline, not yet run on hardware.**
> 88 assertions pass (34 Lua, 54 C++), the firmware builds clean and its
> composition is verified in the shipped bytes. What has not happened is a
> panel and a norns in the same room. [Bring-up](#bring-up) is written for
> exactly that, and says what to check first.

---

## How it fits together

```
   ┌───────────────┐                                  ┌──────────────────┐
   │     norns     │  ──── /pf/scr  frames :9002 ───▶ │   Patternflow    │
   │               │                                  │                  │
   │ mod:          │  ◀── /patternflow/knob/N/delta ─ │  feature:        │
   │ patternflow   │      /patternflow/button/N/held  │  screencast      │
   │               │                                  │                  │
   │ (plain Lua,   │  ──── /patternflow/ping :9001 ─▶ │  (out-of-tree,   │
   │  no fork)     │                                  │   no fork)       │
   └───────────────┘                                  └──────────────────┘
        :10111
```

Neither side is forked.

- **norns** needs no fork because `screen.peek` (read the framebuffer) and
  `/remote/enc` (drive an encoder from OSC) are both stock. Everything on that
  side is a plain-Lua system mod.
- **Patternflow** needs no fork because upstream documents and CI-enforces an
  *out-of-tree composition*: your feature and your two composition files are
  copied over a checkout of core, never merged into it. Core lives here as a
  pristine submodule, our diff against upstream is empty, and taking an update
  is a `git checkout` with nothing to resolve.

The reasoning, with sources, is in
[docs/01-verified-facts.md](docs/01-verified-facts.md) — read that before
changing anything load-bearing.

## Layout

```
docs/
  01-verified-facts.md   every load-bearing fact, read out of the source, with citations
  02-wire-protocol.md    the three conversations, the ports, the frame format
  03-architecture.md     mirror vs co-render; where the animation should live
  04-roadmap.md          milestones M0-M6 and what is explicitly not planned
  05-prior-art.md        ndi-mod, norns.online, and the capture fallback
  archive/               the original session notes, superseded (see its README)
src/
  norns/mod/patternflow/ the norns system mod: control in, mirror out, handshake
  patternflow/
    features/screencast/ the panel-side feature (composeFrame + its own UDP socket)
    bundles/norns/       the two files that define our firmware edition
tools/
  build-firmware.sh      out-of-tree build: compose, check, build, verify composition
  hosttest/              compiles the real feature on a desktop and drives it
  test_mod.lua           drives the real mod against stubbed norns globals
  run_lua_tests.py       runner for the above
vendor/
  patternflow/           submodule, pristine
  norns/                 submodule, API reference
  ndi-mod/               submodule, the capture fallback
```

## Setup

### 0. Clone

```bash
git clone --recurse-submodules <this repo>
# or, in an existing clone:
git submodule update --init --depth 1
```

`vendor/patternflow` is about 210 MB even shallow.

### 1. Flash the panel

You need [PlatformIO](https://platformio.org/). The build composes our feature
onto the vendored core, runs upstream's own boundary checks, builds, and then
scans the finished image to prove it carries exactly the features it claims:

```bash
tools/build-firmware.sh                        # build
tools/build-firmware.sh flash patternflow.local  # build and push over OTA
```

Set your Wi-Fi first, in
`vendor/patternflow/firmware/patternflow/patternflow_secrets.h` (copy
`patternflow_secrets.example.h`). That file is gitignored on both sides —
`net_config.h` bakes it into the image, so a build made with it carries your
Wi-Fi password in plaintext. Fine for your own panel; never publish one.

You do **not** need to set `PF_OSC_REMOTE_PORT` there. Our edition's
`overrides.h` already pins it to 10111, and
[the reason it must be pinned](docs/01-verified-facts.md#the-osc-feature--ports-vocabulary-and-the-port-gotcha)
is the least obvious thing in this project.

The edition is the stock **Audio** feature set plus the mirror, so the panel
keeps its DAW, browser-audio and microphone paths.

### 2. Install the norns mod

```bash
scp -r src/norns/mod/patternflow we@norns.local:/home/we/dust/code/
```

Then on norns: **SYSTEM → MODS → patternflow → enable**, and restart.

### 3. Point it at the panel

**SYSTEM → MODS → patternflow** opens a menu with `control`, `mirror`, `fps`,
`host` and a `re-ping` action. If `patternflow.local` does not resolve from
norns, set `host` to the panel's IP (the panel's own NETWORK screen shows it).
E2 selects, E3 changes, K3 toggles or fires, K2 saves and exits.

## Bring-up

In this order, because each step's failure looks different:

1. **The link.** The mod menu header reads `linked` once the panel has sent
   anything. If it says `no panel`, the panel does not know where norns is or
   `host` is wrong — try `re-ping`, then an IP instead of `.local`.
2. **Control.** Turn panel knob 2. It should move whatever norns encoder 2
   moves. This uses only stock firmware behaviour on both sides, so if the
   mirror is broken but this works, the problem is in the screencast half.
3. **The mirror.** It should appear within a second. `curl
   http://<panel>/api/status` reports `screencast: {live, frames, chunks,
   dropped}` — `frames` climbing with `dropped` at zero is a healthy link.
4. **Hue.** Panel knob 4, which is deliberately left unmapped on the norns side.
   At home position the mirror is plain white; turning right walks the hue
   circle.

Two things worth knowing when something is odd:

- The mirror yields to the panel's own UI. While a Patternflow menu, the
  brightness bar or the info screen is up, the pattern comes back — that is
  `chromeVisible`, and it is intentional.
- Panel channel 4 is left alone on purpose. Long-pressing encoder 4 is how the
  panel switches its own patterns, and knob 4 is the hue control. Channels 1–3
  map to norns.

## Tests

```bash
python tools/run_lua_tests.py    # 34 assertions: the mod, against stubbed norns
bash tools/hosttest/run.sh       # 54 assertions: the real feature, on the desktop
bash tools/build-firmware.sh     # builds, and proves the composition
```

The host test needs a compiler that can link something this machine can run. It
detects one and, if all it finds is an embedded cross-compiler, says so and
type-checks instead of pretending to pass. `pip install ziglang` is the
one-line way to get a real one on any platform.

Two of these tests are doing more than they look:

- `tools/hosttest/gen_stub.py` lifts the `PFFeature` and `InputFrame` struct
  bodies **verbatim out of the vendored core** and compiles our descriptor
  against them. Upstream's own header warns that adjacent same-typed fields in
  a positional initializer reorder without any compiler diagnostic; this is
  that missing diagnostic.
- `tools/build-firmware.sh` scans the finished binary for one marker string per
  feature, so an edition that quietly built the wrong composition fails the
  build rather than the bring-up.

## Credits

[Patternflow](https://github.com/engmung/Patternflow) by engmung — an unusually
well-documented firmware whose feature system is the reason this needs no fork.
[norns](https://github.com/monome/norns) by monome.
[ndi-mod](https://github.com/Dewb/ndi-mod) by Dewb, which is where the redraw-
wrapping technique comes from.
