// Host test for features/screencast/.
//
// Compiles the real feature sources against generated stubs and drives them
// with byte-exact OSC datagrams — built the way liblo builds them, which is
// to say with every number as a big-endian float32, because that is all
// norns can put on the wire.
//
// What this is actually protecting:
//   - the OSC reader, which is hand-rolled and full of offsets
//   - float-typed integers, the norns quirk that would otherwise be found
//     on hardware at the worst moment
//   - bounds: short packets, wrong lengths, bad hex, out-of-range chunks
//   - that our positional PFFeature initializer still matches upstream's
//     field order (that is a compile-time check — see gen_stub.py)
//
// Run with tools/hosttest/run.sh

#include <cstdint>
#include <cstring>
#include <cstdio>
#include <string>
#include <vector>

unsigned long g_millis = 1000;

#include "features/screencast/feature_screencast.h"

namespace SC = PatternflowScreencast;

static int passed = 0, failed = 0;

static void ok(bool cond, const std::string& name) {
  if (cond) { passed++; printf("  ok   %s\n", name.c_str()); }
  else      { failed++; printf("  FAIL %s\n", name.c_str()); }
}

// ── Build OSC datagrams exactly as liblo does ───────────────────────────

static void pushStr(std::vector<uint8_t>& b, const std::string& s) {
  for (char c : s) b.push_back((uint8_t)c);
  b.push_back(0);
  while (b.size() % 4) b.push_back(0);
}

static void pushF32(std::vector<uint8_t>& b, float v) {
  uint32_t bits;
  memcpy(&bits, &v, 4);
  b.push_back((bits >> 24) & 0xFF);
  b.push_back((bits >> 16) & 0xFF);
  b.push_back((bits >> 8) & 0xFF);
  b.push_back(bits & 0xFF);
}

static void pushI32(std::vector<uint8_t>& b, int32_t v) {
  uint32_t u = (uint32_t)v;
  b.push_back((u >> 24) & 0xFF);
  b.push_back((u >> 16) & 0xFF);
  b.push_back((u >> 8) & 0xFF);
  b.push_back(u & 0xFF);
}

// The message the norns mod sends: /pf/scr ,ffs chunk nchunks payload
static std::vector<uint8_t> frameMsg(int chunk, int nchunks, const std::string& payload,
                                     bool asInt = false) {
  std::vector<uint8_t> b;
  pushStr(b, "/pf/scr");
  pushStr(b, asInt ? ",iis" : ",ffs");
  if (asInt) { pushI32(b, chunk); pushI32(b, nchunks); }
  else       { pushF32(b, (float)chunk); pushF32(b, (float)nchunks); }
  pushStr(b, payload);
  return b;
}

static bool feed(const std::vector<uint8_t>& b) {
  return SC::handleDatagram(b.data(), b.size());
}

static std::string hexRun(char c, size_t n) { return std::string(n, c); }

int main() {
  // begin() needs Wi-Fi and a socket; allocate the buffers directly instead.
  SC::levels = (uint8_t*)PFMem::alloc(SC::SRC_PX);
  SC::scratch = (uint8_t*)PFMem::alloc(SC::SRC_PX * 3);
  SC::ready = true;
  SC::runtimeEnabled = true;

  printf("wire format\n");
  const size_t px = SC::SRC_PX / 8;  // 1024
  ok(feed(frameMsg(0, 8, hexRun('f', px))), "a well-formed chunk 0 is accepted");
  ok(SC::levels[0] == 15, "'f' decodes to level 15");
  ok(SC::levels[px - 1] == 15, "the whole band is written");
  ok(SC::levels[px] == 0, "the next band is untouched");

  ok(feed(frameMsg(7, 8, hexRun('8', px))), "chunk 7 is accepted");
  ok(SC::levels[7 * px] == 8, "'8' decodes to level 8");
  ok(SC::levels[SC::SRC_PX - 1] == 8, "the last pixel of the panel is written");

  ok(feed(frameMsg(1, 8, hexRun('a', px), /*asInt=*/true)), "int32-typed args also work");
  ok(SC::levels[px] == 10, "'a' decodes to level 10");

  // Every hex digit round-trips.
  {
    std::string mixed;
    const char* digits = "0123456789abcdef";
    for (size_t i = 0; i < px; i++) mixed += digits[i % 16];
    ok(feed(frameMsg(2, 8, mixed)), "a mixed-level chunk is accepted");
    bool allGood = true;
    for (int i = 0; i < 16; i++) if (SC::levels[2 * px + i] != i) allGood = false;
    ok(allGood, "every level 0-15 round-trips through hex");
    ok(feed(frameMsg(3, 8, std::string(px, 'A'))), "uppercase hex is tolerated");
    ok(SC::levels[3 * px] == 10, "'A' decodes to level 10");
  }

  printf("\nkeepalive and liveness\n");
  g_millis = 5000;
  ok(feed(frameMsg(0, 8, hexRun('f', px))), "a frame refreshes liveness");
  ok(SC::active(), "the mirror is active right after a packet");
  g_millis = 5000 + PF_SCREENCAST_TIMEOUT_MS + 1;
  ok(!SC::active(), "the mirror goes idle after the timeout");
  {
    std::vector<uint8_t> ping;
    pushStr(ping, "/pf/scr/ping");
    ok(feed(ping), "the keepalive is accepted");
    ok(SC::active(), "a keepalive alone keeps the mirror up");
  }

  printf("\nmalformed input is refused, not obeyed\n");
  {
    uint8_t before = SC::levels[0];
    ok(!feed(frameMsg(0, 8, hexRun('z', px))), "non-hex payload is rejected");
    ok(SC::levels[0] == before || SC::levels[0] == 15,
       "a rejected chunk does not scribble a partial band's worth of garbage");

    ok(!feed(frameMsg(0, 8, hexRun('f', px - 1))), "a short payload is rejected");
    ok(!feed(frameMsg(0, 8, hexRun('f', px + 1))), "a long payload is rejected");
    ok(!feed(frameMsg(8, 8, hexRun('f', px))), "an out-of-range chunk index is rejected");
    ok(!feed(frameMsg(-1, 8, hexRun('f', px))), "a negative chunk index is rejected");
    ok(!feed(frameMsg(0, 7, hexRun('f', px))), "an nchunks that doesn't divide the panel is rejected");
    ok(!feed(frameMsg(0, 0, hexRun('f', px))), "nchunks of zero is rejected (no divide by zero)");
    ok(!feed(frameMsg(0, 999, hexRun('f', px))), "an absurd nchunks is rejected");

    std::vector<uint8_t> other;
    pushStr(other, "/patternflow/knob/1/delta");
    pushStr(other, ",f");
    pushF32(other, 1.0f);
    ok(!feed(other), "an unrelated OSC address is ignored");

    // Truncation at every length must not read past the end. Under ASan a
    // single overrun here fails the run.
    std::vector<uint8_t> full = frameMsg(0, 8, hexRun('f', px));
    for (size_t n = 0; n < full.size(); n++) SC::handleDatagram(full.data(), n);
    ok(true, "every truncation of a valid packet is handled without overrun");

    std::vector<uint8_t> noNul;
    noNul.push_back('/'); noNul.push_back('p'); noNul.push_back('f');
    ok(!SC::handleDatagram(noNul.data(), noNul.size()), "an unterminated address is rejected");
    ok(!SC::handleDatagram(nullptr, 0), "an empty datagram is rejected");
  }

  printf("\nchunking arithmetic\n");
  {
    // 4 chunks of 2048 must land in the same places as 8 of 1024.
    memset(SC::levels, 0, SC::SRC_PX);
    const size_t px4 = SC::SRC_PX / 4;
    ok(feed(frameMsg(2, 4, hexRun('c', px4))), "a 4-chunk frame is accepted");
    ok(SC::levels[2 * px4] == 12 && SC::levels[3 * px4 - 1] == 12,
       "chunk 2 of 4 covers the third quarter");
    ok(SC::levels[2 * px4 - 1] == 0, "and nothing before it");
  }

  printf("\ncompose\n");
  {
    memset(SC::levels, 0, SC::SRC_PX);
    SC::levels[0] = 15;   // full white
    SC::levels[1] = 0;    // black
    SC::levels[2] = 8;    // mid
    g_millis = 20000;
    SC::lastPacketMs = g_millis;
    SC::chromeUp = false;
    SC::hueClicks = 0;
    SC::paletteStale = true;

    const uint8_t* out = SC::compose(nullptr, SC::SRC_W, SC::SRC_H);
    ok(out != nullptr, "compose returns a buffer while the mirror is live");
    ok(out[0] == 255 && out[1] == 255 && out[2] == 255, "level 15 with no tint is white");
    ok(out[3] == 0 && out[4] == 0 && out[5] == 0, "level 0 is black");
    ok(out[6] == out[7] && out[7] == out[8] && out[6] > 100 && out[6] < 160,
       "level 8 is mid grey");

    SC::chromeUp = true;
    ok(SC::compose(nullptr, SC::SRC_W, SC::SRC_H) == nullptr,
       "compose yields while the device's own UI is up");
    SC::chromeUp = false;

    ok(SC::compose(nullptr, 64, 32) == nullptr, "compose refuses a panel that isn't 128x64");

    g_millis += PF_SCREENCAST_TIMEOUT_MS + 1;
    ok(SC::compose(nullptr, SC::SRC_W, SC::SRC_H) == nullptr,
       "compose hands the panel back when frames stop");
    SC::lastPacketMs = g_millis;

    SC::runtimeEnabled = false;
    ok(SC::compose(nullptr, SC::SRC_W, SC::SRC_H) == nullptr,
       "compose yields when the feature is switched off at the device");
    SC::runtimeEnabled = true;
  }

  printf("\nhue\n");
  {
    SC::hueClicks = 0;
    SC::nudgeHue(-5);
    ok(SC::hueClicks == 0, "hue does not wind below its white home position");
    SC::nudgeHue(1);
    SC::paletteStale = true;
    const uint8_t* out = SC::compose(nullptr, SC::SRC_W, SC::SRC_H);
    ok(out != nullptr, "compose still works with a tint");
    ok(!(out[0] == out[1] && out[1] == out[2]), "one click off home is no longer grey");
    ok(out[3] == 0 && out[4] == 0 && out[5] == 0, "black stays black at any hue");

    SC::nudgeHue(10000);
    ok(SC::hueClicks == PF_SCREENCAST_HUE_RANGE, "hue clamps at the top of its range");
    SC::paletteStale = true;
    out = SC::compose(nullptr, SC::SRC_W, SC::SRC_H);
    ok(out != nullptr, "the top of the hue range composes");

    // Walk the whole circle. At every hue the palette has to stay a usable
    // ramp: black at the bottom, lit at the top, and never going backwards in
    // between — a hue that dimmed as norns brightened would read as a bug in
    // the script, not in the mirror.
    bool blackFloor = true, litTop = true, monotonic = true;
    for (int c = 0; c <= PF_SCREENCAST_HUE_RANGE; c++) {
      SC::hueClicks = c;
      SC::buildPalette();
      if (SC::palette[0][0] || SC::palette[0][1] || SC::palette[0][2]) blackFloor = false;
      int top = SC::palette[15][0] + SC::palette[15][1] + SC::palette[15][2];
      if (top < 200) litTop = false;
      int prev = -1;
      for (int lvl = 0; lvl < 16; lvl++) {
        int sum = SC::palette[lvl][0] + SC::palette[lvl][1] + SC::palette[lvl][2];
        if (sum < prev) monotonic = false;
        prev = sum;
      }
    }
    ok(blackFloor, "level 0 is black at every hue");
    ok(litTop, "level 15 is properly lit at every hue");
    ok(monotonic, "brightness never goes backwards as the norns level rises");
  }

  printf("\nstatus json\n");
  {
    String json;
    SC::appendStatus(json);
    std::string s = json.c_str();
    ok(s.rfind(",\"screencast\":{", 0) == 0, "status starts with a leading comma, as the hook asks");
    ok(s.back() == '}', "status is balanced");
    ok(s.find("\"port\":9002") != std::string::npos, "status reports the port");
  }

  printf("\n%d passed, %d failed\n", passed, failed);
  return failed == 0 ? 0 : 1;
}
