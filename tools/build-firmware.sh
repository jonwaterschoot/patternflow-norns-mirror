#!/usr/bin/env bash
#
# Build the "norns" Patternflow firmware, out of tree.
#
#   tools/build-firmware.sh                 build
#   tools/build-firmware.sh flash <host>    build, then push over OTA
#   tools/build-firmware.sh checks          just run upstream's boundary checks
#
# The recipe is upstream's own, from FEATURE_GUIDE.md and features/features.h:
# a variant's features and its two composition files are COPIED over a
# checkout of core, rather than merged into it. So vendor/patternflow stays
# pristine, our diff against upstream is zero, and taking an update is
#
#     git -C vendor/patternflow fetch --depth 1 origin <tag>
#     git -C vendor/patternflow checkout FETCH_HEAD
#
# with nothing to resolve. The copies are removed again at the end, so the
# submodule is left exactly as it was found — check with `git -C
# vendor/patternflow status`.
set -euo pipefail
cd "$(dirname "$0")/.."

CORE=vendor/patternflow
SKETCH="$CORE/firmware/patternflow"
FEATURES="$SKETCH/features"
BUNDLE=src/patternflow/bundles/norns

if [ ! -d "$SKETCH" ]; then
  echo "vendor/patternflow is empty — run: git submodule update --init --depth 1" >&2
  exit 1
fi

# xtensa's linker cannot open output files under a path containing non-ASCII,
# and upstream's build.sh works around the same thing. Keep ours somewhere
# plain for the same reason.
BUILD_DIR="${PF_BUILD_DIR:-$HOME/pf-build}"

SECRETS="$SKETCH/patternflow_secrets.h"
COPIED_SECRETS=0

cleanup() {
  rm -rf "$FEATURES/screencast" \
         "$FEATURES/features_local.h" \
         "$FEATURES/overrides.h"
  # Only remove the secrets file if WE put it there. Somebody who keeps theirs
  # inside the submodule the upstream way should not have it deleted by a build.
  [ "$COPIED_SECRETS" = 1 ] && rm -f "$SECRETS"
  return 0
}
trap cleanup EXIT

echo "==> composing"
cp -r src/patternflow/features/screencast "$FEATURES/"
cp "$BUNDLE/features_local.h" "$FEATURES/"
cp "$BUNDLE/overrides.h"      "$FEATURES/"

# Your Wi-Fi credentials belong in THIS repo's root, not inside the submodule.
# vendor/patternflow is a disposable checkout — a submodule bump, a re-init or a
# `git clean -fdx` in there is a normal thing to do and would take the file with
# it. Keeping it here means the one file you had to write by hand survives all
# of that, and it is gitignored on this side too.
#
# A file already inside the sketch still wins, so an existing upstream-style
# setup keeps working untouched.
if [ -f patternflow_secrets.h ] && [ ! -f "$SECRETS" ]; then
  cp patternflow_secrets.h "$SECRETS"
  COPIED_SECRETS=1
  echo "    using ./patternflow_secrets.h"
elif [ -f patternflow_secrets.h ] && [ -f "$SECRETS" ]; then
  echo "    NOTE: ignoring ./patternflow_secrets.h — the submodule already has one"
fi

echo "==> upstream checks"
# check_boundaries is the one that matters to us: it fails if any CORE file
# names a feature. Our feature adds files and edits none, so this passing is
# the evidence that the out-of-tree promise still holds.
python "$CORE/firmware/toolchain/check_boundaries.py"
python "$CORE/firmware/toolchain/check_sources.py"

if [ "${1:-}" = "checks" ]; then
  echo "==> checks only, stopping here"
  exit 0
fi

PIO="$(command -v pio || true)"
[ -n "$PIO" ] || PIO="$HOME/.platformio/penv/Scripts/pio.exe"
[ -x "$PIO" ] || { echo "PlatformIO not found — install it, or put pio on PATH" >&2; exit 1; }

# The four libraries upstream vendors into lib/ have to exist before
# PlatformIO resolves lib_deps, which happens before any extra script runs —
# so a fresh checkout fails with "Could not find the package with
# 'lib/WebSockets'" unless they are cloned first. Same list, same repos and
# same depth as upstream's own bundles/build.sh. lib/ is gitignored in the
# core, so this leaves the submodule clean.
echo "==> vendored libraries"
for pair in \
  "HUB75 https://github.com/mrfaptastic/ESP32-HUB75-MatrixPanel-DMA.git" \
  "Adafruit_GFX https://github.com/adafruit/Adafruit-GFX-Library.git" \
  "Adafruit_BusIO https://github.com/adafruit/Adafruit_BusIO.git" \
  "WebSockets https://github.com/Links2004/arduinoWebSockets.git"; do
  read -r name url <<< "$pair"
  if [ ! -d "$SKETCH/lib/$name" ]; then
    echo "    cloning $name"
    git clone -q --depth 1 "$url" "$SKETCH/lib/$name"
  fi
done

echo "==> building"
( cd "$SKETCH" && PLATFORMIO_BUILD_DIR="$BUILD_DIR" "$PIO" run -e firmware )

BIN="$BUILD_DIR/firmware/firmware.bin"
[ -f "$BIN" ] || BIN="$SKETCH/.pio/build/firmware/firmware.bin"
echo "==> built: $BIN ($(stat -c%s "$BIN" 2>/dev/null || echo '?') bytes)"

# Prove the image carries exactly the features we asked for, by scanning the
# shipped bytes for one marker string per feature. This is upstream's own
# discipline (bundles/build.sh "all") and it catches what the compiler cannot:
# a features_local.h that built the wrong composition while staying green.
#
# grep -F matters here. Every marker is bracketed, and without it "[MQTT] " is
# a character class that matches almost any binary — the scan then reports
# every feature as present and is worse than not running.
echo "==> composition"
scan_fail=0
for m in '[SCR] listening on' '/pf/scr' '/patternflow/knob' '[AUDIO] Ready' '[MIDI] rtp listening'; do
  grep -qaF -- "$m" "$BIN" || { echo "    MISSING: $m"; scan_fail=1; }
done
for m in '[MQTT] ' '[SHOW] ' 'openweathermap' '[CLOCK] /clock ready' '[BLE] setup advertising'; do
  grep -qaF -- "$m" "$BIN" && { echo "    LEAKED:  $m"; scan_fail=1; }
done
if [ "$scan_fail" = 0 ]; then
  echo "    ok — osc, screencast, audio, audio_in, midi; nothing else"
else
  echo "    composition scan FAILED" >&2
  exit 1
fi

# net_config.h bakes whatever patternflow_secrets.h defines straight into the
# image, so a build made with that file present carries your Wi-Fi password in
# plaintext. Upstream warns about this and has shipped one by accident before;
# inherit the warning rather than rediscover it.
if [ -f "$SKETCH/patternflow_secrets.h" ]; then
  echo
  echo "    NOTE: built WITH patternflow_secrets.h — your Wi-Fi credentials are"
  echo "          in this image. Fine for your own panel. Do NOT publish it."
fi

if [ "${1:-}" = "flash" ]; then
  HOST="${2:-patternflow.local}"
  echo "==> flashing $HOST over OTA"
  # upload_protocol is set explicitly rather than left to PlatformIO's
  # guess-from-the-port-name heuristic: the core's platformio.ini configures no
  # protocol at all, and a hostname that fails the heuristic falls back to
  # serial and reports a confusing "no COM port" instead of an OTA failure.
  #
  # If this route gives you trouble, the web console is the reliable one and
  # needs no toolchain: http://<panel>/update, upload the .bin printed above.
  ( cd "$SKETCH" \
    && PLATFORMIO_UPLOAD_PROTOCOL=espota \
       PLATFORMIO_UPLOAD_PORT="$HOST" \
       PLATFORMIO_BUILD_DIR="$BUILD_DIR" \
       "$PIO" run -e firmware -t upload )
fi
