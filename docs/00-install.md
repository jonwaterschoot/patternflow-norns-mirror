# 00 — Install guide

Start to finish: a Patternflow panel and a norns that talk to each other.

Two halves, and **they are independent** — the panel half is a firmware flash,
the norns half is copying a folder. Do them in either order. Nothing is
destructive: the panel keeps every pattern and setting through the reflash, and
the norns mod is one directory you can delete.

Budget about 40 minutes the first time, most of it waiting for a toolchain to
download.

> **This has not been run on hardware yet.** Every step below is derived from
> the two upstream codebases (with sources in
> [01-verified-facts.md](01-verified-facts.md)) and the firmware builds clean,
> but nobody has yet done this with a real panel and a real norns. Expect at
> least one thing to be wrong. [Troubleshooting](#troubleshooting) is where to
> look, and please write down what you find.

---

## What you need

| | |
|---|---|
| A Patternflow panel | any v3 board; 128 × 64 P2.5 |
| A norns | or shield / shield-XL. Nothing here is shield-specific |
| Both on **the same 2.4 GHz Wi-Fi** | the ESP32 has no 5 GHz radio, and the two must be on the same subnet |
| A computer with Python 3 and git | for the firmware build |
| Your panel's Wi-Fi credentials | |

You do **not** need: a soldering iron, a USB cable (unless something goes
wrong), an Arduino IDE, or a norns fork.

---

# Part 1 — the panel

## 1.1 Find your panel and note its IP

Long-press **encoder 2** (≥1 s) on the panel. The NETWORK screen shows Wi-Fi
state, the local IP, and OSC's state. Write the IP down — you will want it if
`patternflow.local` turns out not to resolve.

If the panel has never been on your Wi-Fi, set that up first with upstream's
browser flasher or the Improv serial setup — see Patternflow's own
[BUILD_GUIDE](https://github.com/engmung/Patternflow). Come back when
`http://<panel-ip>` opens the console in a browser.

Check what is on it now:

```bash
curl http://patternflow.local/api/status      # or use the IP
```

You are looking at `variant` and `caps`. Any edition works as a starting
point — the reflash replaces whatever is there.

## 1.2 Clone this repo with its submodules

```bash
git clone --recurse-submodules https://github.com/<you>/patternflow_norns
cd patternflow_norns
```

If you already cloned it without submodules:

```bash
git submodule update --init --depth 1
```

`vendor/patternflow` is around 210 MB even shallow. It is a pristine checkout
of upstream and **nothing in this project ever edits it** — the build copies
our files in, builds, and takes them out again.

## 1.3 Install PlatformIO

```bash
pip install platformio
```

That is the whole dependency. The ESP32-S3 toolchain (a few hundred MB)
downloads by itself on the first build.

> **Windows:** build from a path with no non-ASCII characters. The xtensa
> linker cannot write outputs under a path it cannot encode. Our build script
> already puts the build tree in `~/pf-build` for this reason; override it with
> `PF_BUILD_DIR` if that path is also awkward.

## 1.4 Set your Wi-Fi credentials

```bash
cd vendor/patternflow/firmware/patternflow
cp patternflow_secrets.example.h patternflow_secrets.h
cd -
```

Edit `patternflow_secrets.h` and set:

```c
#define PF_WIFI_SSID "your-wifi-name"
#define PF_WIFI_PASS "your-wifi-password"
```

Leave everything else commented out. In particular **do not set
`PF_OSC_REMOTE_PORT`** — our edition's `overrides.h` already pins it to 10111,
which is the single most important setting in this project and
[the reason is worth reading](01-verified-facts.md#the-osc-feature--ports-vocabulary-and-the-port-gotcha).

> `patternflow_secrets.h` is gitignored in both repos, because `net_config.h`
> bakes it straight into the image: **a firmware built with this file contains
> your Wi-Fi password in plaintext.** Fine for your own panel. Never publish
> one. The build prints a reminder when it detects the file.

## 1.5 Build

```bash
tools/build-firmware.sh
```

What it does, in order: copies our feature and our two composition files onto
the vendored core, runs **upstream's own** boundary checkers, clones the four
libraries upstream vendors, builds, scans the finished image to prove it
carries exactly the features it claims, and removes our copies again.

A clean run ends with:

```
==> built: /home/you/pf-build/firmware/firmware.bin (1152384 bytes)
==> composition
    ok — osc, screencast, audio, audio_in, midi; nothing else
```

First build is a few minutes (toolchain download); after that about 40 seconds.

Confirm the core was left untouched — this should print nothing:

```bash
git -C vendor/patternflow status --porcelain
```

## 1.6 Flash it

**Route A — the web console. Recommended, and needs no toolchain.**

Open `http://patternflow.local/update` (or `http://<ip>/update`) and upload the
`firmware.bin` the build printed. The panel reboots into it.

Uploads are accepted at any time by default. If your build has
`PF_WEBUPDATE_ALWAYS_ARMED 0`, you must first open the UPDATE screen on the
device: long-press **K2** → NETWORK, then **turn K4**.

**Route B — OTA from the command line.**

```bash
tools/build-firmware.sh flash patternflow.local
```

Needs mDNS (UDP 5353) and the OTA port (3232) open between your computer and
the panel. Route A is more reliable across networks.

**Route C — USB.** Only if the panel will not come up on Wi-Fi at all. Build
first, then from `vendor/patternflow/firmware/patternflow`:

```bash
pio run -e firmware -t upload --upload-port COM5     # or /dev/ttyUSB0
```

Note this builds *stock core with no features* unless our files are in place —
so use it for recovery, not for installing this project.

## 1.7 Verify the panel

```bash
curl http://patternflow.local/api/status
```

You want `"variant":"norns"` and `screencast` in `caps`. There should also be a
`screencast` object:

```json
"screencast": { "on": true, "live": false, "port": 9002,
                "hue": 0, "frames": 0, "chunks": 0, "dropped": 0 }
```

`live: false` and `frames: 0` are correct at this point — norns is not sending
anything yet.

### One thing that changed on the NETWORK screen

Long-press encoder 2 again. The screen has room for exactly **two** feature
toggle rows, and they are the first two toggleable features in the edition's
list. On this edition that is:

| | |
|---|---|
| **turn K2** | `OSC` on / off |
| **turn K3** | `SCR` on / off — **the mirror** |

Turn right for on, left for off. Rotation, not clicks, so that holding K2 to
leave cannot flip anything on the way out.

On the stock Audio edition K3 toggles audio-react. Here the mirror takes that
row, because being able to kill the mirror at the device — to see the pattern
underneath without a reflash — is worth more on a norns-paired panel than a
mic toggle. `AUD` and `MIDI` are still there and still work; they are just
web-console-only now. If you would rather have it the other way, move
`&PFFeatureScreencast::descriptor` further down the list in
[`src/patternflow/bundles/norns/features_local.h`](../src/patternflow/bundles/norns/features_local.h)
and rebuild.

---

# Part 2 — norns

## 2.1 Copy the mod across

```bash
scp -r src/norns/mod/patternflow we@norns.local:/home/we/dust/code/
```

The default password is `sleep`. If `norns.local` does not resolve, use the IP
from norns's SYSTEM → WIFI screen.

The result must be exactly:

```
~/dust/code/patternflow/lib/mod.lua
```

> **The folder must be named `patternflow`.** norns finds mods by globbing
> `*/lib/mod.lua` under `~/dust/code/` and takes the mod's name from the
> *directory*. That name is what the mod registers its menu under and where it
> writes its config, so renaming the folder quietly moves both.

No git, no dependencies, no build. It is one Lua file.

## 2.2 Enable it, then restart

On norns: **K1** → **SYSTEM** → **MODS**.

The controls here are not the obvious ones:

| | |
|---|---|
| **E2** | scroll the list |
| **E3 right** | enable · **E3 left** | disable |
| **K3** | enter that mod's own menu (only once it is loaded) |
| **K2** | back |

So: scroll to `PATTERNFLOW` with E2, then **turn E3 right**. A `+` appears at
the right of the row, meaning *enabled but not yet loaded*.

Now **SYSTEM → RESTART**. Mods load at startup; the `+` is the menu telling you
a restart is owed.

After the restart the row should show a leading `.` (loaded) and a trailing `>`
(it has a menu). If you get `.` but no `>`, the mod loaded but its menu did not
register — check `maiden`'s REPL output for a Lua error.

## 2.3 Point it at the panel

**SYSTEM → MODS → PATTERNFLOW → K3** opens the mod's menu.

| setting | what it does |
|---|---|
| `control` | panel encoders and buttons drive norns |
| `mirror` | the norns screen is sent to the panel |
| `fps` | mirror rate cap, 1–30. 20 is the default |
| `host` | the panel: `patternflow.local`, or its IP |
| `re-ping` | send the handshake again now |

**E2** selects a row, **E3** changes it, **K3** toggles or fires an action,
**K2** saves and exits.

The header reads `linked` once the panel has sent anything, `no panel` before
that. If it stays `no panel`, set `host` to the panel's raw IP — norns
resolving `.local` is the most likely thing to fail here — and hit `re-ping`.

Settings are saved to `~/dust/data/patternflow/config.lua` when you leave with
K2.

---

# Part 3 — bring-up

In this order, because each step fails differently and the order isolates it.

### 1. The link

The mod menu header says `linked`.

If not: the panel does not know where norns is. Try `re-ping`; then an IP
instead of `.local`; then confirm both devices really are on the same subnet
(compare the first three octets of the panel's NETWORK-screen IP and norns's
WIFI-screen IP).

### 2. Control

Leave the mod menu. Turn **panel knob 2**. It should move whatever norns
encoder 2 moves — in the menus, or in whatever script is loaded.

This step uses only stock behaviour on both sides: Patternflow already sends
knob events, and norns already answers `/remote/enc`. So if this works and the
mirror does not, the problem is entirely in the screencast half — which is a
very useful thing to know.

Push **panel button 2**: it should act as norns K2.

Panel channel **4** is deliberately unmapped — long-pressing encoder 4 is how
the panel switches its own patterns, and knob 4 is the hue control below.

### 3. The mirror

The norns screen should appear on the panel within a second.

```bash
curl http://patternflow.local/api/status
```

`frames` climbing and `dropped` at zero is a healthy link. What the numbers
mean if they are not:

| reading | meaning |
|---|---|
| `live: false`, `frames: 0` | nothing is arriving. `mirror` off in the mod menu, wrong `host`, or a firewall between them |
| `frames: 0` but `dropped` climbing | packets arrive and are refused — a protocol mismatch. Mod and firmware out of step with each other |
| `frames` climbing, `dropped` climbing too | some datagrams are malformed or oversized. Lower `fps`; check Wi-Fi congestion |
| `frames` climbing, `live: false` | you polled between keepalives. Poll again |

A static norns screen sends nothing but keepalives — that is the design, not a
fault. Move an encoder on norns and watch `frames` move.

### 4. Hue

Turn **panel knob 4**. At its home position the mirror is plain white; turning
right walks the hue circle, and norns's grey levels survive as brightness
within that hue. Turn all the way back left for white again.

Hue persists across reboots. Panel brightness is separate and stays where it
always was: long-press K1.

---

## Troubleshooting

| symptom | likely cause | fix |
|---|---|---|
| Build: `Could not find the package with 'lib/WebSockets'` | the vendored libraries were not cloned | the build script does this for you — re-run it rather than calling `pio` directly |
| Build: linker cannot write output | non-ASCII in the build path (Windows) | set `PF_BUILD_DIR` to a plain path |
| `git -C vendor/patternflow status` is dirty | a build was interrupted before cleanup | `git -C vendor/patternflow checkout .` and `git clean -fd` inside it |
| Mod does not appear in MODS | wrong path or wrong folder name | it must be `~/dust/code/patternflow/lib/mod.lua` |
| Mod shows `+` and never loads | the restart has not happened | SYSTEM → RESTART |
| Mod shows `.` but no `>` | the menu did not register | check maiden's REPL for a Lua error |
| Header stays `no panel` | mDNS, or wrong subnet | use the raw IP; `re-ping` |
| Control works, mirror does not | the screencast half only | check `SCR` is ON (NETWORK screen, turn K3) and `mirror` is on in the mod menu |
| Mirror works, control does not | `PF_OSC_REMOTE_PORT` is not 10111 | you set it in your secrets file and overrode ours, or you flashed a stock edition |
| Mirror freezes, then the pattern returns | keepalives stopped arriving | norns busy, or Wi-Fi dropped. The panel is *supposed* to hand itself back |
| Mirror vanishes while you use the panel's menus | working as intended | the mirror yields while the panel's own UI is up (`chromeVisible`) |
| norns audio glitches while mirroring | the Lua mirror is costing too much | lower `fps`; see [the note on per-send cost](02-wire-protocol.md#one-cost-to-watch-during-bring-up) |
| Panel switches patterns on its own | something is sending `/patternflow/pattern/index` | another OSC host on the network found it |

### Turning it off

- **The mirror only:** NETWORK screen, turn K3 to OFF. Persists across reboots.
- **Everything, on norns:** MODS → PATTERNFLOW, E3 left, restart. Or delete
  `~/dust/code/patternflow`.
- **Back to stock firmware:** flash any edition from
  [the shelf](https://patternflow.work/editions). Patterns, Wi-Fi and settings
  survive.

---

## Updating

**This project:** `git pull && git submodule update --init --depth 1`, then
rebuild and re-copy the mod.

**Upstream Patternflow:** because nothing here forks it, this is just moving
the submodule:

```bash
git -C vendor/patternflow fetch --depth 1 origin <newer-tag>
git -C vendor/patternflow checkout FETCH_HEAD
bash tools/hosttest/run.sh      # do this first — see below
tools/build-firmware.sh
git add vendor/patternflow && git commit -m "bump core to <newer-tag>"
```

Run the host test **before** the build, and take it seriously if it fails to
compile. It regenerates its `PFFeature` stub from the newly checked-out core
and compiles our descriptor against it. Upstream's own header warns that
reordering adjacent same-typed fields in a positional initializer produces no
compiler diagnostic — the firmware would build green and wire our hooks to the
wrong functions. That test is the missing diagnostic, and a bump is exactly
when it earns its keep.
