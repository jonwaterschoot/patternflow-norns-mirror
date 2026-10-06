#!/usr/bin/env bash
#
# Stage a release: the two files a user needs, and the notes that go with them.
#
#   tools/release.sh v0.5.0                 from a clean, committed tree
#   tools/release.sh v0.5.0 --allow-dirty   a dry run from a working tree
#
# Writes dist/<version>/ and stops. Publishing is a separate, deliberate step —
# the last line printed is the `gh release create` command to do it with —
# because a staged image nobody has looked at should not become the thing a
# stranger flashes.
#
#   dist/<version>/assets/patternflow-norns-mirror-<version>.bin   for /update
#   dist/<version>/assets/mod.lua                                  for norns
#   dist/<version>/assets/SHA256SUMS
#   dist/<version>/notes.md                                        the release text
#
# The mod is published as plain `mod.lua` so that
# releases/latest/download/mod.lua is a permanent link the README can use.
#
# ── Why this refuses rather than warns ──────────────────────────────────
#
# net_config.h bakes whatever patternflow_secrets.h defines straight into the
# image, so a build made with that file present carries the builder's Wi-Fi
# password in plaintext. Upstream has published one by accident twice, and
# wrote firmware/bundles/shelf.sh so it could not happen a third time. This is
# that script's discipline, applied to our two places a secrets file can live:
# ./patternflow_secrets.h (ours; build-firmware.sh copies it in) and the one
# inside the sketch (upstream's).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
ALLOW_DIRTY=0
[ "${2:-}" = "--allow-dirty" ] && ALLOW_DIRTY=1
if [ -z "$VERSION" ]; then
  echo "usage: tools/release.sh <version> [--allow-dirty]" >&2
  exit 1
fi
case "$VERSION" in
  v*) ;;
  *) echo "version should start with v (got '$VERSION')" >&2; exit 1 ;;
esac

SKETCH=vendor/patternflow/firmware/patternflow
OUT="dist/$VERSION"
REPO_URL="https://github.com/jonwaterschoot/patternflow-norns-mirror"

# ── The tree ────────────────────────────────────────────────────────────
#
# A release names a commit. Built from uncommitted files, nobody — including
# you, later — could rebuild what was shipped.
if [ "$ALLOW_DIRTY" = 0 ] && [ -n "$(git status --porcelain --ignore-submodules=none)" ]; then
  echo "the working tree has uncommitted changes. Commit first, or pass --allow-dirty for a dry run." >&2
  exit 1
fi
if [ -n "$(git -C vendor/patternflow status --porcelain)" ]; then
  echo "vendor/patternflow is not clean. A release is built from upstream as it is." >&2
  exit 1
fi
COMMIT="$(git rev-parse --short HEAD)"
# From the define the core stamps into every image, not from `git describe`:
# a submodule is checked out without its tags on a fresh clone or a CI runner,
# and describe would then name a bare commit.
CORE_TAG="v$(sed -n 's/^#define PF_IMPROV_FW_VERSION[[:space:]]*"\([^"]*\)".*/\1/p' "$SKETCH/net_config.h" | head -n1)"
[ "$CORE_TAG" != "v" ] || { echo "cannot read the core's version from net_config.h" >&2; exit 1; }

# A version-stamped release is never rebuilt in place: whoever downloaded the
# first one has those bytes, and a second set under the same name is a bug
# report nobody can reproduce. Bump instead.
if [ -d "$OUT" ]; then
  echo "$OUT already exists. Bump the version instead of rebuilding it." >&2
  exit 1
fi

# ── The two halves agree on what they are ───────────────────────────────
#
# They are released together and the wire format changes between versions;
# a mod and a firmware that disagree about their own version are how a
# mismatched pair ships. Both files must say exactly this version.
FW_VERSION="$(sed -n 's/^#define PF_VARIANT_VERSION[[:space:]]*"\([^"]*\)".*/\1/p' src/patternflow/bundles/norns/overrides.h)"
FW_VARIANT="$(sed -n 's/^#define PF_VARIANT[[:space:]]*"\([^"]*\)".*/\1/p' src/patternflow/bundles/norns/overrides.h)"
MOD_VERSION="$(sed -n 's/^local VERSION = "\([^"]*\)".*/\1/p' src/norns/mod/pf-mirror/lib/mod.lua)"
if [ "$FW_VERSION" != "$VERSION" ] || [ "$MOD_VERSION" != "$VERSION" ]; then
  echo "version mismatch: releasing $VERSION, overrides.h says '$FW_VERSION', mod.lua says '$MOD_VERSION'." >&2
  echo "Set PF_VARIANT_VERSION and the mod's VERSION to $VERSION, commit, and run again." >&2
  exit 1
fi

# ── The tests ───────────────────────────────────────────────────────────
echo "==> tests"
python tools/run_lua_tests.py > /dev/null || { echo "Lua tests failed" >&2; exit 1; }
bash tools/hosttest/run.sh > /dev/null 2>&1 || { echo "host test failed — run tools/hosttest/run.sh" >&2; exit 1; }
python tools/check_docs.py > /dev/null || { echo "doc links failed — run tools/check_docs.py" >&2; exit 1; }
echo "    all pass"

# ── Secrets ─────────────────────────────────────────────────────────────
SECRET_FILES=()
for f in patternflow_secrets.h "$SKETCH/patternflow_secrets.h"; do
  [ -f "$f" ] && SECRET_FILES+=("$f")
done

# Every string literal a secrets file defines, minus the ones that are also in
# public source (upstream notes two defaults equal to `patternflow`, which is
# in every image dozens of times and is not a secret).
collect_secrets() {
  local f
  for f in "${SECRET_FILES[@]+"${SECRET_FILES[@]}"}"; do
    grep -oE '^#define[[:space:]]+PF_[A-Z_]+[[:space:]]+"[^"]*"' "$f" \
      | sed -E 's/.*"([^"]*)"/\1/'
  done | sort -u | while IFS= read -r v; do
    [ -n "$v" ] || continue
    if grep -rqaF -- "$v" "$SKETCH/net_config.h" "$SKETCH/config.h" \
         "$SKETCH/patternflow_secrets.example.h" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$v"
  done
}

scan() {   # scan <bin> -> 0 clean, 1 leaking
  local bin="$1" leaked=0 v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    if grep -qaF -- "$v" "$bin"; then
      echo "    LEAK: a secret value is present in the image"
      leaked=1
    fi
  done < <(collect_secrets)
  if ! grep -qa YOUR_WIFI_SSID "$bin"; then
    echo "    the placeholder SSID is missing — this image was not built clean"
    leaked=1
  fi
  return $leaked
}

build() {   # prints the path of the image it built
  local log
  log="$(bash tools/build-firmware.sh 2>&1)" || { echo "$log" >&2; return 1; }
  sed -n 's/^==> built: \(.*\) ([0-9?]* bytes)$/\1/p' <<< "$log" | head -n1
}

# The control build. If the scanner passes an image that DOES carry the
# credentials, it is broken, and a clean result from it means nothing.
if [ "${#SECRET_FILES[@]}" -gt 0 ]; then
  echo "==> control build, with your secrets — the scanner must reject this"
  CONTROL_BIN="$(build)"
  if scan "$CONTROL_BIN" > /dev/null; then
    echo "    the scanner passed an image that HAS your credentials. It is broken." >&2
    echo "    Refusing to release with a scanner that proves nothing." >&2
    exit 1
  fi
  echo "    rejected, as it should be"
fi

# The real build, with every secrets file moved aside. The trap puts them back
# on any exit — a failed build, a Ctrl-C — because they are gitignored and
# there is no other copy of them anywhere.
restore() {
  local f
  for f in "${SECRET_FILES[@]+"${SECRET_FILES[@]}"}"; do
    [ -f "$f.release-aside" ] && mv -f "$f.release-aside" "$f"
  done
  return 0
}
trap restore EXIT
for f in "${SECRET_FILES[@]+"${SECRET_FILES[@]}"}"; do mv "$f" "$f.release-aside"; done

echo "==> clean build"
BIN="$(build)"
[ -f "$BIN" ] || { echo "the build did not say where its image is" >&2; exit 1; }
if ! scan "$BIN"; then
  echo "    refusing to stage it" >&2
  exit 1
fi
echo "    no credentials in the image"
restore

# The panel reports what the binary believes, not what this script was told.
if ! grep -qaF -- "$VERSION" "$BIN" || ! grep -qaF -- "$FW_VARIANT" "$BIN"; then
  echo "the image does not carry \"$FW_VARIANT\" $VERSION — it believes it is something else." >&2
  exit 1
fi

# ── Stage ───────────────────────────────────────────────────────────────
mkdir -p "$OUT/assets"
FW_NAME="patternflow-norns-mirror-$VERSION.bin"
cp "$BIN" "$OUT/assets/$FW_NAME"
cp src/norns/mod/pf-mirror/lib/mod.lua "$OUT/assets/mod.lua"
( cd "$OUT/assets" && sha256sum "$FW_NAME" mod.lua > SHA256SUMS )

cat > "$OUT/notes.md" <<EOF
> **Unofficial.** A personal project, not affiliated with or endorsed by
> Patternflow (Seunghun Lee / engmung) or monome. "Patternflow" is a trademark
> of Seunghun Lee; norns is made by monome. Both names are used only to say
> what this works with.

The norns screen mirrored on a Patternflow panel, in all 16 grey levels,
tinted from the panel's knob 4. Two files: one for each device.

## Install

**Firmware first, then the mod.** A newer firmware understands an older mod;
the other way round shows a dead mirror.

**Patternflow** — needs a panel already running Patternflow firmware and on
your Wi-Fi. Download \`$FW_NAME\` and upload it at
\`http://patternflow.local/update\`. Wi-Fi, patterns and settings survive.
To go back, upload any stock edition the same way.

**norns** — paste this into maiden's REPL (\`http://norns.local\`), then
SYSTEM → MODS → PF-MIRROR, turn E3 right, and SYSTEM → RESTART:

\`\`\`lua
os.execute("mkdir -p /home/we/dust/code/pf-mirror/lib && curl -fsSL -o /home/we/dust/code/pf-mirror/lib/mod.lua $REPO_URL/releases/download/$VERSION/mod.lua")
\`\`\`

Coming from a version before v0.5.0? The mod used to be called
\`patternflow\`: disable it in SYSTEM → MODS (E3 left) and delete
\`~/dust/code/patternflow\`.

## What this firmware changes

It is Patternflow's stock **Audio** edition (OSC, browser audio, microphone,
MIDI) on core $CORE_TAG, plus one feature, \`screencast\`, which listens on UDP
port 9002 and shows the norns screen while frames arrive, then hands the panel
back to its pattern. It also pins the panel's OSC replies to port 10111
(norns's), and keeps the microphone from driving the knobs by default.
\`/update\` keeps working, so you can always leave. The panel reports itself as
\`$FW_VARIANT\` $VERSION at \`/api/status\`.

## Licenses

This project's code is MIT. The firmware image is built from Patternflow's
core (MIT) and libraries under their own licenses, including Adafruit GFX
(BSD), Adafruit BusIO (MIT), ESP32-HUB75-MatrixPanel-DMA (MIT),
arduinoWebSockets (LGPL-2.1), NimBLE-Arduino (Apache-2.0), AppleMIDI
(CC BY-SA 4.0), the Arduino MIDI Library and the Arduino-ESP32 core. Source:
[this repository at $COMMIT]($REPO_URL/tree/$COMMIT) and its submodules.

Built from \`$COMMIT\`, Patternflow core \`$CORE_TAG\`.
EOF

echo "==> staged $OUT"
ls -l "$OUT/assets"
echo
echo "Look at it, then publish with:"
echo "  gh release create $VERSION $OUT/assets/* --repo jonwaterschoot/patternflow-norns-mirror \\"
echo "     --title \"$VERSION\" --notes-file $OUT/notes.md"
