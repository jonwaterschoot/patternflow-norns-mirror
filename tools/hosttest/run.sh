#!/usr/bin/env bash
#
# Compile and run the screencast host test.
#
# The feature's real sources are compiled — only Arduino, Wi-Fi, NVS and the
# allocator are stubbed. The PFFeature/InputFrame stubs are generated from the
# vendored core, so this also fails if upstream reorders a descriptor field
# under our positional initializer.
#
#   CXX=g++ tools/hosttest/run.sh     pick a compiler explicitly
#   NO_ASAN=1 tools/hosttest/run.sh   skip the sanitizers
set -euo pipefail
cd "$(dirname "$0")/../.."

HT=tools/hosttest
OUT="${TMPDIR:-/tmp}/pf_screencast_test"

python "$HT/gen_stub.py"

# The feature's own relative includes (../pf_feature.h, ../../src/core_mem.h,
# ../../config.h) resolve inside the stub tree, so it is laid out to match the
# real firmware's directory shape.
rm -rf "$HT/stub/features/screencast"
mkdir -p "$HT/stub/features/screencast"
cp src/patternflow/features/screencast/*.h "$HT/stub/features/screencast/"

# Find a compiler that can produce something this machine can RUN. A bare
# `g++` on PATH is not proof of that: an embedded toolchain (the Daisy and
# esp-idf installers both put one there) compiles happily and then fails to
# link a hosted binary. So each candidate is test-linked and the result is
# executed before it is trusted.
#
# `zig c++` is in the list because it is the one host compiler you can add on
# any of the three platforms without an installer — `pip install ziglang` —
# which on a Windows box with only an embedded toolchain is the difference
# between running these assertions and only type-checking them.
probe_cxx() {
  local probe="$OUT.probe.cpp"
  echo 'int main(){return 0;}' > "$probe"
  "$@" "$probe" -o "$OUT.probe.exe" >/dev/null 2>&1 || return 1
  "$OUT.probe.exe" >/dev/null 2>&1 || return 1
  rm -f "$probe" "$OUT.probe.exe" "$OUT.probe"
  return 0
}

CXX_CMD=""
pick_cxx() {
  local zig=""
  zig="$(python -c 'import ziglang,os,sys; sys.stdout.write(os.path.join(os.path.dirname(ziglang.__file__), "zig"))' 2>/dev/null || true)"
  local candidates=("${CXX:-}" "g++" "clang++" "c++" "/usr/bin/g++" "/mingw64/bin/g++")
  for c in "${candidates[@]}"; do
    [ -n "$c" ] || continue
    command -v "$c" >/dev/null 2>&1 || continue
    if probe_cxx "$c" -x c++; then CXX_CMD="$c"; return 0; fi
  done
  if [ -n "$zig" ] && probe_cxx "$zig" c++ -x c++; then
    CXX_CMD="$zig c++"
    return 0
  fi
  return 1
}

FLAGS="-std=c++17 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -I $HT/stub"

if pick_cxx; then
  SAN=""
  # shellcheck disable=SC2086
  if [ "${NO_ASAN:-}" = "" ] && probe_cxx $CXX_CMD -fsanitize=address,undefined -x c++; then
    SAN="-fsanitize=address,undefined"
  fi
  echo "==> $CXX_CMD $SAN"
  # shellcheck disable=SC2086
  $CXX_CMD $FLAGS $SAN "$HT/test_screencast.cpp" -o "$OUT.exe"
  "$OUT.exe"
  exit $?
fi

# No hosted compiler. A cross-compiler still type-checks the feature and, more
# to the point, still checks our positional descriptor against the generated
# struct — so run that much and say plainly what was not run.
for c in ${CXX:-} g++ clang++ c++; do
  [ -n "$c" ] || continue
  command -v "$c" >/dev/null 2>&1 || continue
  echo "==> no hosted compiler found; type-checking only with $c"
  # shellcheck disable=SC2086
  "$c" $FLAGS -fsyntax-only "$HT/test_screencast.cpp"
  echo "SYNTAX AND DESCRIPTOR LAYOUT OK — runtime assertions NOT run."
  echo "Install a host compiler (MSYS2 mingw-w64, Xcode CLT, build-essential)"
  echo "to run them."
  exit 0
done

echo "no C++ compiler found at all" >&2
exit 1
