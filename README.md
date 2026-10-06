# patternflow-norns-mirror

The **monome norns** screen, mirrored on a **[Patternflow](https://github.com/engmung/Patternflow)**
panel — an open-source LED synthesiser: a 128 × 64 HUB75 RGB matrix on an
ESP32-S3 with four push-encoders.

> **Unofficial.** A personal project, not affiliated with or endorsed by
> Patternflow (Seunghun Lee / engmung) or monome. "Patternflow" is a trademark
> of Seunghun Lee; norns is made by monome. Both names are used only to say
> what this works with.

Both screens are 128 × 64. That is the coincidence the whole project started with
— a norns frame maps to the panel one pixel to one pixel, with no scaling.

As of the current state I'm still not 100% convinced with the quality of the mirrored image,
the lack of aliasing is making some things look bad.
However, when I started this I was looking for the ways the devices can communicate, and now that this bridge has been built the first time, I'm thinking about what other options are possible. While I already have the option to use the Patternflows encoders to control the norns encoders, I'm more thinking towards a unique combo of scripts to have a script on norns that works in conjunction with Patternflow in a way beyond mere mirroring. TBC.

As most will probably read from the look of this repo, it was built using LLM's, mostly Claude.

## Quickstart

Two files, one for each device, from
[the latest release](https://github.com/jonwaterschoot/patternflow-norns-mirror/releases/latest).
No toolchain, no building. **Panel first.**

**1. Patternflow** — for a panel already running Patternflow and on your
Wi-Fi. Download `patternflow-norns-mirror-<version>.bin` and upload it at
`http://patternflow.local/update`. Wi-Fi, patterns and settings survive; to go
back, upload any stock edition the same way.

**2. norns** — open maiden (`http://norns.local`) and paste this into the REPL:

```lua
os.execute("mkdir -p /home/we/dust/code/pf-mirror/lib && curl -fsSL -o /home/we/dust/code/pf-mirror/lib/mod.lua https://github.com/jonwaterschoot/patternflow-norns-mirror/releases/latest/download/mod.lua")
```

Then SYSTEM → MODS → `PF-MIRROR`, **turn E3 right**, and SYSTEM → RESTART.
Within a few seconds the norns screen is on the panel; panel knob 4 tints it.

[docs/00-install.md](docs/00-install.md) has every step in detail, bring-up,
and troubleshooting.

## What it does

1. **The panel mirrors the norns screen**, in all 16 grey levels, tinted to
   any hue from panel knob 4. Stable on hardware. Close to the OLED, but
   anti-aliased shapes look steppier on the LEDs
   ([why](docs/06-hardware-findings.md#the-picture-is-close-not-identical)).
2. **The panel drives norns** — built, but switched off: on hardware it
   transferred badly, so the mod no longer acts on panel input. See
   [the roadmap](docs/04-roadmap.md#panel-knobs-driving-norns-off-until-understood).
3. **Later: the two co-render** — norns as the brain sending meaning rather
   than pixels, and the panel rendering it in colour. See
   [docs/03-architecture.md](docs/03-architecture.md).

The firmware is Patternflow's stock **Audio** edition plus one feature, the
mirror, so the panel keeps its DAW, browser-audio and microphone paths. It
reports itself as `norns-mirror` at `/api/status`.

---

## How it fits together

```
   ┌───────────────┐                                  ┌──────────────────┐
   │     norns     │  ──── /pf/scr  frames :9002 ───▶ │   Patternflow    │
   │               │                                  │                  │
   │ mod:          │  ◀── /patternflow/knob/N/delta ─ │  feature:        │
   │ pf-mirror     │      (control: switched off)     │  screencast      │
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
  is a `git checkout` with nothing to resolve. In upstream's terms this is a
  *community edition*: its own repository, releases and binary, installed by
  hand through `/update`.

The reasoning, with sources, is in
[docs/01-verified-facts.md](docs/01-verified-facts.md) — read that before
changing anything load-bearing.

## Layout

```
.github/workflows/
  release.yml            a pushed tag builds both files and opens a draft release
docs/
  00-install.md          quick install, building it yourself, bring-up, troubleshooting
  01-verified-facts.md   every load-bearing fact, read out of the source, with citations
  02-wire-protocol.md    the three conversations, the ports, the frame format
  03-architecture.md     mirror vs co-render; where the animation should live
  04-roadmap.md          milestones M0-M6 and what is explicitly not planned
  05-prior-art.md        ndi-mod, norns.online, and the capture fallback
  06-hardware-findings.md what hardware taught us: a faulty panel, memory, the freeze, the look
  archive/               the original session notes, superseded (see its README)
src/
  norns/mod/pf-mirror/   the norns system mod: mirror out, handshake (control in: off)
  patternflow/
    features/screencast/ the panel-side feature (composeFrame + its own UDP socket)
    bundles/norns/       the two files that define our firmware edition
tools/
  build-firmware.sh      out-of-tree build: compose, check, build, verify composition
  release.sh             stage a release: both files, checked for leaked credentials
  hosttest/              compiles the real feature on a desktop and drives it
  test_mod.lua           drives the real mod against stubbed norns globals
  run_lua_tests.py       runner for the above
  check_docs.py          every relative link and #anchor in the docs resolves
vendor/
  patternflow/           submodule, pristine
  norns/                 submodule, API reference
  ndi-mod/               submodule, the capture fallback
build/                   all build output, gitignored — delete it any time
dist/                    staged releases, gitignored
```

## Building it yourself

Only needed to change the firmware.
[docs/00-install.md](docs/00-install.md#part-1--the-panel-building-it-yourself)
has the full version; the short one:

```bash
git clone --recurse-submodules https://github.com/jonwaterschoot/patternflow-norns-mirror.git
cd patternflow-norns-mirror
pip install platformio
tools/build-firmware.sh          # → build/firmware/firmware.bin
                                 # upload that at http://<panel>/update
scp -r src/norns/mod/pf-mirror we@norns.local:/home/we/dust/code/
```

The image needs no Wi-Fi credentials: a panel keeps its own through an update.
You do not need to set `PF_OSC_REMOTE_PORT` either — our `overrides.h` pins it
to 10111, and
[why that is necessary](docs/01-verified-facts.md#the-osc-feature--ports-vocabulary-and-the-port-gotcha)
is the least obvious thing in this project.

### Releasing

Set the new version in both `src/patternflow/bundles/norns/overrides.h`
(`PF_VARIANT_VERSION`) and `src/norns/mod/pf-mirror/lib/mod.lua` (`VERSION`),
commit, push, then tag:

```bash
git tag v0.6.0 && git push origin v0.6.0
```

GitHub Actions ([release.yml](.github/workflows/release.yml)) builds both files
on a clean machine and opens a **draft** release. Read the notes, then press
Publish. A machine that has never seen your Wi-Fi file cannot put it in the
image.

The workflow runs `tools/release.sh`, which also works locally
(`tools/release.sh v0.6.0` → `dist/v0.6.0/`, then the `gh release create`
command it prints). Either way it runs the tests, refuses an image that
carries Wi-Fi credentials (after first proving its scanner catches one that
does), and refuses a tag the firmware and the mod do not both carry.

## Tests

```bash
python tools/run_lua_tests.py    # the mod, against stubbed norns
bash tools/hosttest/run.sh       # the real feature, compiled and driven on the desktop
bash tools/build-firmware.sh     # builds, and proves the composition
python tools/check_docs.py       # every relative link and #anchor resolves
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

## License

MIT, for this project's own code — see [LICENSE](LICENSE). The submodules and
the libraries in the firmware image keep their own licenses; the LICENSE file
lists them.

## Credits

[Patternflow](https://github.com/engmung/Patternflow) by Seunghun Lee (engmung)
— an unusually well-documented firmware whose feature system is the reason
this needs no fork. [norns](https://github.com/monome/norns) by monome.
[ndi-mod](https://github.com/Dewb/ndi-mod) by Dewb, which is where the redraw-
wrapping technique comes from.
