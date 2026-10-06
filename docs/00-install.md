# 00 — Install guide

Start to finish: a Patternflow panel and a norns that talk to each other.

Two halves — a firmware for the panel and a mod for norns. **Do the panel
first**: a newer firmware understands an older mod, but not the other way
round. Nothing is destructive: the panel keeps every pattern, setting and its
Wi-Fi through the update, and the norns mod is one directory you can delete.

Two ways in:

- **[Quick install](#quick-install--from-a-release)** — download the two files
  from a release. About five minutes, no toolchain. This is the one to use.
- **[Building it yourself](#part-1--the-panel-building-it-yourself)** — for
  changing the firmware. About 40 minutes the first time, most of it waiting
  for a toolchain to download.

---

## What you need

| | |
|---|---|
| A Patternflow panel | any v3 board; 128 × 64 P2.5 |
| A norns | or shield / shield-XL. Nothing here is shield-specific |
| Both on **the same 2.4 GHz Wi-Fi** | the ESP32 has no 5 GHz radio, and the two must be on the same subnet |
| A panel already running Patternflow and on your Wi-Fi | the update keeps its Wi-Fi. A brand-new board: install stock firmware first from [patternflow.work](https://patternflow.work) |
| A computer with Python 3 and git | only for building it yourself |

You do **not** need: a soldering iron, a USB cable (unless something goes
wrong), an Arduino IDE, or a norns fork.

## Quick install — from a release

**1. The panel.** Download `patternflow-norns-mirror-<version>.bin` from
[the latest release](https://github.com/jonwaterschoot/patternflow-norns-mirror/releases/latest). Open
`http://patternflow.local/update` (or `http://<panel-ip>/update`) and upload
it. The panel reboots into it with its Wi-Fi, patterns and settings intact.
`http://patternflow.local/api/status` should now say
`"variant":"norns-mirror"`. To go back, upload any stock edition the same way.

**2. norns.** Open maiden (`http://norns.local`, or the IP from SYSTEM → WIFI),
paste this into the REPL at the bottom, and press Enter:

```lua
os.execute("mkdir -p /home/we/dust/code/pf-mirror/lib && curl -fsSL -o /home/we/dust/code/pf-mirror/lib/mod.lua https://github.com/jonwaterschoot/patternflow-norns-mirror/releases/latest/download/mod.lua")
```

It downloads one file, `~/dust/code/pf-mirror/lib/mod.lua`. Prefer a terminal?
`scp` the release's `mod.lua` to that same path instead (password `sleep`).

**3. Enable it.** On norns: SYSTEM → MODS, scroll to `PF-MIRROR`, **turn E3
right**, then SYSTEM → RESTART. [2.2](#22-enable-it-then-restart) explains the
MODS screen if it looks odd.

**4. Bring it up** — [Part 3](#part-3--bring-up). The mod's menu header should
read `linked` within a few seconds, and the norns screen appears on the panel.

Coming from a version before v0.5.0? The mod used to be called `patternflow`:
disable that one in SYSTEM → MODS (E3 left) and delete
`~/dust/code/patternflow`, or norns will run both.

---

## Which terminal

For building it yourself, and for the troubleshooting commands.

**Every command block below is a POSIX shell command**, run from the root of
this repo. That matters on Windows.

- **macOS / Linux:** any terminal. Nothing special.
- **Windows: use Git Bash, not PowerShell and not cmd.** `tools/*.sh` are bash
  scripts, and `cp`, `scp` and `curl` behave differently or not at all in
  PowerShell.

Git Bash ships with Git for Windows, so if you can run `git` you already have
it. In VS Code, open the terminal (`` Ctrl+` ``), click the **∨** next to the
`+` on the terminal tab bar, and pick **Git Bash**. To make it the default:
`Ctrl+Shift+P` → *Terminal: Select Default Profile* → *Git Bash*.

To run one command from a PowerShell prompt without switching:

```powershell
& "C:\Program Files\Git\bin\bash.exe" tools/build-firmware.sh
```

Two things that look wrong in Git Bash and are not: paths print as
`/c/Users/you/...` rather than `C:\Users\you\...` (same place, different
spelling), and `~` is your Windows user folder.

---

# Part 1 — the panel, building it yourself

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

**Already have the repo?** Then work in it — there is no separate build or
test directory, and nothing below wants a clean checkout. Everything this
project generates lands in the gitignored `build/`, and
the build leaves `vendor/patternflow` byte-identical to upstream every time.
Skip to [1.3](#13-install-platformio) once `git submodule status` shows all
three with no leading `-`.

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

**Already have the PlatformIO VS Code extension?** Then you have it, even
though `pio` is probably not on your PATH — the extension keeps it in its own
virtualenv. `tools/build-firmware.sh` looks there
(`~/.platformio/penv/Scripts/pio.exe`, or `bin/pio` on macOS and Linux) when
`pio` is not on PATH, so you can skip this step. You only need `pio` on PATH if
you intend to call it directly, which is just the USB recovery route in 1.6.

> **A note on non-ASCII paths.** The xtensa linker cannot write outputs under
> a path it cannot encode, so if this repo lives somewhere with an accent or a
> non-Latin character in it, the build script notices, says so, and builds in
> `~/pf-build` instead. Set `PF_BUILD_DIR` to put it anywhere you like.

## 1.4 Wi-Fi credentials — probably skip this

**If your panel is already on your Wi-Fi, do nothing here.** Credentials
provisioned through the browser flasher or Improv live in a separate NVS
partition, `core_wifi.h` prefers them over anything compiled in, and a firmware
update does not erase them. The panel will come back on the same network. It
remembers up to five.

You only need a secrets file if the panel has *never* been on this Wi-Fi and
you would rather bake the credentials in than provision over USB.

If you do need one, put it at **the root of this repo** — not in the submodule:

```bash
cp vendor/patternflow/firmware/patternflow/patternflow_secrets.example.h \
   ./patternflow_secrets.h
```

and set just these two lines:

```c
#define PF_WIFI_SSID "your-wifi-name"
#define PF_WIFI_PASS "your-wifi-password"
```

`tools/build-firmware.sh` copies it into the sketch for the build and removes
it again afterwards, exactly like it does with the feature. Keeping it here
rather than in `vendor/patternflow` matters because that checkout is
disposable — bumping the submodule, re-initialising it, or a `git clean -fdx`
in there are all normal things to do, and any of them would take the one file
you wrote by hand with it. A file already inside the submodule still wins, so
an existing upstream-style setup keeps working.

Leave everything else commented out. In particular **do not set
`PF_OSC_REMOTE_PORT`** — our edition's `overrides.h` already pins it to 10111,
which is the single most important setting in this project and
[the reason is worth reading](01-verified-facts.md#the-osc-feature--ports-vocabulary-and-the-port-gotcha).

> The file is gitignored on both sides, because `net_config.h` bakes it
> straight into the image: **a firmware built with it contains your Wi-Fi
> password in plaintext.** Fine for your own panel. Never publish one. The
> build prints a reminder whenever it used one.

## 1.5 Build

From the **root of this repo**, in a [POSIX shell](#which-terminal) — on
Windows that means Git Bash:

```bash
cd /c/Users/you/Documents/GitHub/patternflow_norns   # wherever you cloned it
tools/build-firmware.sh
```

If it says `permission denied`, the execute bit did not survive the clone. Run
it through bash instead — same result:

```bash
bash tools/build-firmware.sh
```

What it does, in order: copies our feature and our two composition files onto
the vendored core, runs **upstream's own** boundary checkers, clones the four
libraries upstream vendors, builds, scans the finished image to prove it
carries exactly the features it claims, and removes our copies again.

A clean run ends with:

```
==> built: /c/Users/you/…/patternflow_norns/build/firmware/firmware.bin (1152384 bytes)
           C:\Users\you\…\patternflow_norns\build\firmware\firmware.bin
==> composition
    ok — osc, screencast, audio, audio_in, midi; nothing else
```

**`build/firmware/firmware.bin`, inside this repo** — that is the file you
upload in the next step. On Windows the second line is the same path in the
form a file picker wants; the `/c/...` one is Git Bash's spelling of it.

First build is a few minutes (toolchain download); after that about 25 seconds.

Everything the build produces stays in `build/`, which is gitignored:
`firmware/` for the image and `libdeps/` for the libraries PlatformIO resolved.
Delete the whole directory to start clean — nothing in it is precious.

Confirm the core was left untouched — this should print nothing:

```bash
git -C vendor/patternflow status --porcelain
```

## 1.6 Flash it

**Route A — the web console. Recommended, and needs no toolchain.**

Open `http://patternflow.local/update` (or `http://<ip>/update`) and upload
**`build/firmware/firmware.bin`** from this repo. The panel reboots into it.

The other files beside it — `bootloader.bin`, `partitions.bin`, `firmware.elf`
— are not what you want here. `/update` takes the application image only.

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

You want `"variant":"norns-mirror"` and `screencast` in `caps`. There should also be a
`screencast` object:

```json
"screencast": { "on": true, "live": false, "port": 9002, "hue": 0,
                "frames": 0, "chunks": 0, "dropped": 0, "levels": 0, ... }
```

`live: false`, `frames: 0` and `levels: 0` are correct at this point — norns
is not sending anything yet. Once it is, `levels` reads `16`.

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

From maiden's REPL, the release's copy — see
[Quick install](#quick-install--from-a-release). Or, from this repo:

```bash
scp -r src/norns/mod/pf-mirror we@norns.local:/home/we/dust/code/
```

The default password is `sleep`. If `norns.local` does not resolve, use the IP
from norns's SYSTEM → WIFI screen.

The result must be exactly:

```
~/dust/code/pf-mirror/lib/mod.lua
```

> **The folder must be named `pf-mirror`.** norns finds mods by globbing
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

So: scroll to `PF-MIRROR` with E2, then **turn E3 right**. A `+` appears at
the right of the row, meaning *enabled but not yet loaded*.

Now **SYSTEM → RESTART**. Mods load at startup; the `+` is the menu telling you
a restart is owed.

After the restart the row should show a leading `.` (loaded) and a trailing `>`
(it has a menu). If you get `.` but no `>`, the mod loaded but its menu did not
register — check `maiden`'s REPL output for a Lua error.

## 2.3 Point it at the panel

**SYSTEM → MODS → PF-MIRROR → K3** opens the mod's menu.

| setting | what it does |
|---|---|
| `mirror` | the norns screen is sent to the panel |
| `fps` | mirror rate cap, 1–40. 20 is the default; lower it first if norns feels loaded |
| `host` | the panel: `patternflow.local`, or its IP |
| `test` | `off` / `diag` / `rows` / `line` / `ramp` — see [Diagnosing a display fault](#diagnosing-a-display-fault) |
| `line y` | which row the `line` card lights, 0–63 |
| `re-ping` | send the handshake again now |

**E2** selects a row, **E3** changes it, **K3** toggles or fires an action,
**K2** saves and exits.

The header says where things stand:

| header | meaning |
|---|---|
| `finding panel` | looking `host` up (in the background; norns stays responsive) |
| `no address` | the lookup failed. Nothing is sent; it tries again every 5 s |
| `no panel` | an address, but the panel has not answered yet |
| `linked` | the panel has sent something in the last 10 s |

If it stays at `no address` or `no panel`, set `host` to the panel's raw IP
in `~/dust/data/pf-mirror/config.lua` — norns resolving `.local` is the most
likely thing to fail here — and hit `re-ping`. Once the panel has answered,
the mod uses the address the panel's own packets come from, so mDNS only has
to work once.

Settings are saved to `~/dust/data/pf-mirror/config.lua` when you leave with
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

### 2. The mirror

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

### 3. Hue

Turn **panel knob 4**. At its home position the mirror is plain white; turning
right walks the hue circle, and norns's grey levels survive as brightness
within that hue. Turn all the way back left for white again.

Hue persists across reboots. Panel brightness is separate and stays where it
always was: long-press K1.

---

## Diagnosing a display fault

If the mirror is up but the picture is wrong — a row doubled, shifted or
missing — the first question is whether the bad pixels *arrived* that way or
were *drawn* that way. The mod's test cards and the panel's `/api/status`
answer it from opposite ends, and between them there is nowhere for the fault
to hide.

The cards are a **mode**, not a one-shot: while one is selected the mirror
sends it instead of the norns screen, so it stays on the panel while you walk
around the menus looking at it.

**SYSTEM → MODS → PF-MIRROR → K3**, then the `test` row:

| card | what it shows | what it proves |
|---|---|---|
| `diag` | a one-pixel diagonal crossing every row exactly once, plus faint bars every 16 rows at the chunk boundaries | a row that is duplicated, dropped or shifted is a visible step in an otherwise straight line. The bars show whether a fault sits on a chunk edge |
| `rows` | every other row lit | adjacent rows are **never** equal by construction. If the panel shows solid bands or paired rows, the doubling happened after the data |
| `ramp` | all 16 grey levels as 8-px bands, rising left to right on the top half and falling on the bottom | hold it beside the norns screen. Two bands that look alike on the panel but not on the OLED were lost to the panel's brightness curve, not the wire. `screencast.levels` in `/api/status` should read `16` |
| `line` | a single lit row, moved with `line y` | move it and watch. If the doubling follows it everywhere, it is systematic; if it only happens at one position, it is specific to those rows |

Then ask the panel what it thinks it has:

```bash
curl http://patternflow.local/api/status
```

`screencast.rowdup` counts how many adjacent row pairs are byte-identical in
the buffer the panel is about to draw, and `rowdupfirst` is the first such row.

**With the `rows` card selected, `rowdup` must be 0.** So:

- `rowdup: 0` and you can still see doubling → the data arrived correct and
  something downstream of it doubled the row: the blit, the HUB75 driver, or
  the panel. Nothing in this project can cause that.
- `rowdup` greater than 0 with the `rows` card up → the duplication is in the
  data, and `rowdupfirst` says where. That is ours, and worth reporting.

A blank screen legitimately reports `rowdup: 63` — every row matches its
neighbour because they are all black. The number only means something against
a card that makes neighbours differ.

### Read the brightness, not just the position

The `line` card is level 15 on one row and 0 on every other, with nothing in
between. A second row lighting up *dimmer* is showing a brightness that is not
in the data, so it happened after the pixels arrived — in the driver or the
panel, not in this project. Two rows at *equal* brightness would be ours, and
`rowdup` would say so. A dead LED cannot double a row either: it is a hole in a
fixed place, never a repeat.

One panel did exactly this, and the fix was a replacement panel; see
[06-hardware-findings.md](06-hardware-findings.md#a-row-pair-doubled-on-one-panel--the-panel).
If you have a spare panel, swap it in before spending an evening on driver
settings.

### Is the panel even running the firmware you think?

`/api/status` reports `variantVersion`. If it is not what the bundle's
`overrides.h` says, the panel is a build behind and you may be chasing
something already fixed — `rowdup` missing from `screencast` entirely means
exactly that.

### `dropped` climbing

`screencast.dropped` counts datagrams the panel refused. A mod and a firmware
from different commits will drop **everything**, because the payload length no
longer matches what the chunk header promises — so a large `dropped` that is no
longer growing is just the history of the minutes before you updated both
halves. To tell which:

```bash
curl -s http://patternflow.local/api/status | grep -o '"dropped":[0-9]*'
sleep 30
curl -s http://patternflow.local/api/status | grep -o '"dropped":[0-9]*'
```

Unchanged is fine and needs nothing. Still climbing means the two halves are
out of step, or something else on the network is talking to port 9002.

## Troubleshooting

| symptom | likely cause | fix |
|---|---|---|
| `tools/build-firmware.sh : The term ... is not recognized` | you are in PowerShell | use Git Bash — see [Which terminal](#which-terminal) |
| `permission denied` running a `.sh` | the execute bit did not survive the clone | `bash tools/build-firmware.sh` |
| `PlatformIO not found` | `pio` is not on PATH and not in the extension's venv | `pip install platformio` |
| Build: `Could not find the package with 'lib/WebSockets'` | the vendored libraries were not cloned | the build script does this for you — re-run it rather than calling `pio` directly |
| Build: linker cannot write output | non-ASCII somewhere in the repo path | the script should catch this and say so; if not, set `PF_BUILD_DIR` to a plain path |
| Build behaves oddly after a submodule bump | stale objects in `build/` | delete `build/` and rebuild |
| `git -C vendor/patternflow status` is dirty | a build was interrupted before cleanup | `git -C vendor/patternflow checkout .` and `git clean -fd` inside it |
| Mod does not appear in MODS | wrong path or wrong folder name | it must be `~/dust/code/pf-mirror/lib/mod.lua` |
| Mod shows `+` and never loads | the restart has not happened | SYSTEM → RESTART |
| Mod shows `.` but no `>` | the menu did not register | check maiden's REPL for a Lua error |
| Header stays `no address` or `no panel` | mDNS, or wrong subnet | use the raw IP; `re-ping` |
| norns freezes — screen, encoders and menus — with the mod enabled | a mod from before 2026-10-05 sending to a `.local` name that has stopped resolving; every send blocked on the lookup | update the mod. To get norns back first: [recovering a frozen norns](#recovering-a-frozen-norns) |
| `linked`, but no mirror | the screencast half only | check `SCR` is ON (NETWORK screen, turn K3) and `mirror` is on in the mod menu |
| Panel knobs do nothing on norns | working as intended, for now | control is switched off in the mod; see [the roadmap](04-roadmap.md#panel-knobs-driving-norns-off-until-understood) |
| Mirror works, header stays `no panel` | `PF_OSC_REMOTE_PORT` is not 10111 | you set it in your secrets file and overrode ours, or you flashed a stock edition |
| Mirror freezes, then the pattern returns | keepalives stopped arriving | norns busy, or Wi-Fi dropped. The panel is *supposed* to hand itself back |
| The pattern keeps coming back whenever norns is idle | the heartbeat is not running | a mod older than the reserved-metro fix; or another mod took metro `metro_id` (35). Both halves must be updated together |
| Gradients come out as 8 steps, `screencast.levels` is `8` | the mod is older than the firmware | re-copy the mod. The firmware takes both encodings, so this is the harmless way round |
| Mirror dead after updating the mod; `dropped` climbing | the firmware is older than the mod | an older firmware refuses 16-level chunks. Flash firmware v0.4.0 or later |
| Frames visibly fill in top to bottom | mod and firmware are out of step | `/pf/scr/end` is what publishes a frame; a mod without it, or a firmware without it, tears. Re-copy the mod and reflash |
| Rows look duplicated or shifted | worth isolating | [Diagnosing a display fault](#diagnosing-a-display-fault) — the test cards and `rowdup` together say whether the data or the panel is at fault |
| A test card flashes up and disappears | a mod older than the test-*mode* change | the cards are a mode now and hold until set back to `off`. Re-copy the mod |
| Mirror vanishes while you use the panel's menus | working as intended | the mirror yields while the panel's own UI is up (`chromeVisible`) |
| norns audio glitches while mirroring | the Lua mirror is costing too much | lower `fps`; see [the note on per-send cost](02-wire-protocol.md#the-cost-that-shapes-all-of-this) |
| Panel switches patterns on its own | something is sending `/patternflow/pattern/index` | another OSC host on the network found it |

### Recovering a frozen norns

No OS reset is needed. norns loads a mod only if it finds
`~/dust/code/<name>/lib/mod.lua`, so take that file away and restart.
`norns.local` may not resolve either while this is going on; use the IP from
your router's client list.

```bash
ssh we@<norns-ip>                       # password: sleep
mv ~/dust/code/pf-mirror ~/pf-mirror.off
sudo reboot
```

Or with maiden (`http://<norns-ip>`): in the file browser, delete or replace
`code/pf-mirror/lib/mod.lua`, then power-cycle norns. maiden's file
handling is its own server and keeps working while matron is stuck; its REPL
does not. Or simply bring the panel back onto the network: once the name
resolves again, the sends stop stalling and norns catches up.

### Turning it off

- **The mirror only:** NETWORK screen, turn K3 to OFF. Persists across reboots.
- **Everything, on norns:** MODS → PF-MIRROR, E3 left, restart. Or delete
  `~/dust/code/pf-mirror`.
- **Back to stock firmware:** flash any edition from
  [the shelf](https://patternflow.work/editions). Patterns, Wi-Fi and settings
  survive.

---

## Updating

**This project:** `git pull && git submodule update --init --depth 1`, then
rebuild, flash, and re-copy the mod — **firmware first**. A newer firmware
still understands an older mod; an older firmware may not understand a newer
mod, and shows a dead mirror.

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
