// Host test for features/screencast/.
//
// Compiles the real feature sources against generated stubs and drives them
// with byte-exact OSC datagrams — built the way liblo builds them, which is
// to say with every number as a big-endian float32, because that is all
// norns can put on the wire.
//
// What this is actually protecting:
//   - the OSC reader, which is hand-rolled and full of offsets
//   - the pixel-pair packing, where swapping the two halves would be a
//     plausible-looking picture with every column wrong
//   - double buffering, i.e. that a half-arrived frame never reaches the panel
//   - float-typed integers, the norns quirk that would otherwise be found
//     on hardware at the worst moment
//   - bounds: short packets, wrong lengths, bad symbols, out-of-range chunks
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

static std::vector<uint8_t> endMsg() {
  std::vector<uint8_t> b;
  pushStr(b, "/pf/scr/end");
  return b;
}

static bool feed(const std::vector<uint8_t>& b) {
  return SC::handleDatagram(b.data(), b.size());
}

// One character encodes a PIXEL PAIR: a * LEVELS + b into the alphabet.
static char sym(int a, int b) { return SC::ALPHABET[a * SC::LEVELS + b]; }
static std::string pairRun(int a, int b, size_t chars) {
  return std::string(chars, sym(a, b));
}

int main() {
  // begin() needs Wi-Fi and a socket; allocate the buffers directly instead.
  SC::levels = (uint8_t*)PFMem::alloc(SC::SRC_PX);
  SC::pending = (uint8_t*)PFMem::alloc(SC::SRC_PX);
  SC::scratch = (uint8_t*)PFMem::alloc(SC::SRC_PX * 3);
  SC::ready = true;
  SC::runtimeEnabled = true;

  const size_t px = SC::SRC_PX / 4;   // 2048 pixels per chunk
  const size_t chars = px / 2;        // 1024 characters

  printf("wire format\n");
  ok(feed(frameMsg(0, 4, pairRun(7, 7, chars))), "a well-formed chunk 0 is accepted");
  ok(SC::pending[0] == 7 && SC::pending[1] == 7, "one character decodes to two pixels");
  ok(SC::pending[px - 1] == 7, "the whole band is written");
  ok(SC::pending[px] == 0, "the next band is untouched");

  ok(feed(frameMsg(3, 4, pairRun(4, 4, chars))), "the last chunk is accepted");
  ok(SC::pending[SC::SRC_PX - 1] == 4, "the last pixel of the panel is written");

  ok(feed(frameMsg(1, 4, pairRun(2, 5, chars), /*asInt=*/true)),
     "int32-typed args also work");
  ok(SC::pending[px] == 2 && SC::pending[px + 1] == 5,
     "the two halves of a pair are not swapped");

  {
    std::string mixed;
    for (size_t i = 0; i < chars; i++) {
      mixed += sym((int)(i % SC::LEVELS), (int)((i / SC::LEVELS) % SC::LEVELS));
    }
    ok(feed(frameMsg(2, 4, mixed)), "a mixed-level chunk is accepted");
    bool allGood = true;
    for (size_t i = 0; i < 32; i++) {
      if (SC::pending[2 * px + i * 2] != (uint8_t)(i % SC::LEVELS)) allGood = false;
      if (SC::pending[2 * px + i * 2 + 1] != (uint8_t)((i / SC::LEVELS) % SC::LEVELS))
        allGood = false;
    }
    ok(allGood, "every level 0-7 round-trips in both halves of the pair");
  }

  printf("\ndouble buffering — the fix for banded tearing\n");
  {
    memset(SC::levels, 0, SC::SRC_PX);
    memset(SC::pending, 0, SC::SRC_PX);
    ok(feed(frameMsg(0, 4, pairRun(7, 7, chars))), "a chunk arrives");
    ok(SC::levels[0] == 0, "and is NOT shown yet — no half-drawn frame reaches the panel");
    ok(SC::pending[0] == 7, "it waits in the back buffer");
    ok(feed(endMsg()), "the frame-complete marker is accepted");
    ok(SC::levels[0] == 7, "which publishes the whole frame at once");

    ok(feed(frameMsg(1, 4, pairRun(3, 3, chars))), "a later frame changes one band");
    ok(feed(endMsg()), "and completes");
    ok(SC::levels[0] == 7, "the band that did not change is still there");
    ok(SC::levels[px] == 3, "the band that did is updated");
  }

  printf("\nkeepalive and liveness\n");
  g_millis = 5000;
  ok(feed(frameMsg(0, 4, pairRun(7, 7, chars))), "a frame refreshes liveness");
  ok(SC::active(), "the mirror is active right after a packet");
  g_millis = 5000 + PF_SCREENCAST_TIMEOUT_MS + 1;
  ok(!SC::active(), "the mirror goes idle after the timeout");
  ok(feed(endMsg()), "the frame-complete marker alone is accepted");
  ok(SC::active(), "and keeps the mirror up — this is the idle-screen keepalive");

  printf("\nmalformed input is refused, not obeyed\n");
  {
    memset(SC::pending, 1, SC::SRC_PX);
    std::string bad = pairRun(7, 7, chars);
    bad[chars - 1] = '~';   // not in the alphabet
    ok(!feed(frameMsg(0, 4, bad)), "a symbol outside the alphabet is rejected");
    bool untouched = true;
    for (size_t i = 0; i < px; i++) if (SC::pending[i] != 1) untouched = false;
    ok(untouched, "and not one pixel was written before the refusal");

    ok(!feed(frameMsg(0, 4, pairRun(7, 7, chars - 1))), "a short payload is rejected");
    ok(!feed(frameMsg(0, 4, pairRun(7, 7, chars + 1))), "a long payload is rejected");
    ok(!feed(frameMsg(4, 4, pairRun(7, 7, chars))), "an out-of-range chunk index is rejected");
    ok(!feed(frameMsg(-1, 4, pairRun(7, 7, chars))), "a negative chunk index is rejected");
    ok(!feed(frameMsg(0, 3, pairRun(7, 7, chars))),
       "an nchunks that does not divide the panel is rejected");
    ok(!feed(frameMsg(0, 0, pairRun(7, 7, chars))),
       "nchunks of zero is rejected (no divide by zero)");
    ok(!feed(frameMsg(0, 999, pairRun(7, 7, chars))), "an absurd nchunks is rejected");

    std::vector<uint8_t> other;
    pushStr(other, "/patternflow/knob/1/delta");
    pushStr(other, ",f");
    pushF32(other, 1.0f);
    ok(!feed(other), "an unrelated OSC address is ignored");

    // Truncation at every length must not read past the end. Under a
    // sanitizer a single overrun here fails the run.
    std::vector<uint8_t> full = frameMsg(0, 4, pairRun(7, 7, chars));
    for (size_t n = 0; n < full.size(); n++) SC::handleDatagram(full.data(), n);
    ok(true, "every truncation of a valid packet is handled without overrun");

    std::vector<uint8_t> noNul;
    noNul.push_back('/'); noNul.push_back('p'); noNul.push_back('f');
    ok(!SC::handleDatagram(noNul.data(), noNul.size()),
       "an unterminated address is rejected");
    ok(!SC::handleDatagram(nullptr, 0), "an empty datagram is rejected");
  }

  printf("\nchunking arithmetic\n");
  {
    memset(SC::pending, 0, SC::SRC_PX);
    const size_t px8 = SC::SRC_PX / 8;
    ok(feed(frameMsg(5, 8, pairRun(6, 6, px8 / 2))), "an 8-chunk frame is accepted");
    ok(SC::pending[5 * px8] == 6 && SC::pending[6 * px8 - 1] == 6,
       "chunk 5 of 8 covers exactly its own band");
    ok(SC::pending[5 * px8 - 1] == 0, "nothing before it");
    ok(SC::pending[6 * px8] == 0, "and nothing after it — no bleed into the next band");
  }

  printf("\ncompose\n");
  {
    memset(SC::levels, 0, SC::SRC_PX);
    SC::levels[0] = 7;   // full white
    SC::levels[1] = 0;   // black
    SC::levels[2] = 4;   // mid
    g_millis = 20000;
    SC::lastPacketMs = g_millis;
    SC::chromeUp = false;
    SC::hueClicks = 0;
    SC::paletteStale = true;

    const uint8_t* out = SC::compose(nullptr, SC::SRC_W, SC::SRC_H);
    ok(out != nullptr, "compose returns a buffer while the mirror is live");
    ok(out[0] == 255 && out[1] == 255 && out[2] == 255,
       "the top level with no tint is white");
    ok(out[3] == 0 && out[4] == 0 && out[5] == 0, "level 0 is black");
    ok(out[6] == out[7] && out[7] == out[8] && out[6] > 100 && out[6] < 160,
       "the middle level is mid grey");

    SC::chromeUp = true;
    ok(SC::compose(nullptr, SC::SRC_W, SC::SRC_H) == nullptr,
       "compose yields while the device's own UI is up");
    SC::chromeUp = false;

    ok(SC::compose(nullptr, 64, 32) == nullptr,
       "compose refuses a panel that is not 128x64");

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

    // Walk the whole circle. At every hue the palette has to stay a usable
    // ramp: black at the bottom, lit at the top, and never going backwards in
    // between — a hue that dimmed as norns brightened would read as a bug in
    // the script, not in the mirror.
    bool blackFloor = true, litTop = true, monotonic = true;
    for (int c = 0; c <= PF_SCREENCAST_HUE_RANGE; c++) {
      SC::hueClicks = c;
      SC::buildPalette();
      if (SC::palette[0][0] || SC::palette[0][1] || SC::palette[0][2]) blackFloor = false;
      const int top = SC::palette[SC::LEVELS - 1][0] + SC::palette[SC::LEVELS - 1][1] +
                      SC::palette[SC::LEVELS - 1][2];
      if (top < 200) litTop = false;
      int prev = -1;
      for (int lvl = 0; lvl < SC::LEVELS; lvl++) {
        const int sum = SC::palette[lvl][0] + SC::palette[lvl][1] + SC::palette[lvl][2];
        if (sum < prev) monotonic = false;
        prev = sum;
      }
    }
    ok(blackFloor, "level 0 is black at every hue");
    ok(litTop, "the top level is properly lit at every hue");
    ok(monotonic, "brightness never goes backwards as the norns level rises");
  }

  printf("\nstanding the pattern down while the mirror is up\n");
  {
    auto frameWith = [](int patternIndex) {
      PFFeatureFrame f{};
      f.patternIndex = patternIndex;
      f.running = true;
      f.chromeVisible = false;
      return f;
    };
    const int BLACK = g_blackIndex;   // 3, per the registry stub
    const int MINE = 11;              // whatever the user had running
    int idx = -1;

    SC::blanked = false;
    SC::restoreIdx = -1;
    SC::blackIdx = -2;
    SC::wantSwitch = false;
    SC::runtimeEnabled = true;
    SC::chromeUp = false;

    // Mirror idle: nothing should be asked for.
    SC::lastPacketMs = 0;
    g_millis = 50000;
    SC::noteFrame(frameWith(MINE));
    ok(!SC::consumePatternRequest(&idx), "an idle mirror asks for no pattern change");

    // Mirror goes live: ask for Black, remembering what was running.
    SC::lastPacketMs = g_millis;
    SC::noteFrame(frameWith(MINE));
    ok(SC::consumePatternRequest(&idx), "going live asks for a pattern change");
    ok(idx == BLACK, "and the one it asks for is Black");
    ok(!SC::consumePatternRequest(&idx), "the request is consumed exactly once");

    // Still live, now showing Black: no further requests.
    SC::noteFrame(frameWith(BLACK));
    ok(!SC::consumePatternRequest(&idx), "it does not keep asking once blanked");

    // Mirror stops: ask for the original back.
    g_millis += PF_SCREENCAST_TIMEOUT_MS + 1;
    SC::noteFrame(frameWith(BLACK));
    ok(SC::consumePatternRequest(&idx), "going idle asks again");
    ok(idx == MINE, "and restores what was running before");

    // If something else changed the pattern while mirroring, that choice is
    // newer than ours and must not be overwritten on the way out.
    SC::blanked = false; SC::restoreIdx = -1; SC::wantSwitch = false;
    SC::lastPacketMs = g_millis;
    SC::noteFrame(frameWith(MINE));
    ok(SC::consumePatternRequest(&idx) && idx == BLACK, "blanks again");
    const int SOMETHING_ELSE = 7;
    g_millis += PF_SCREENCAST_TIMEOUT_MS + 1;
    SC::noteFrame(frameWith(SOMETHING_ELSE));
    ok(!SC::consumePatternRequest(&idx),
       "a pattern chosen during mirroring is left alone on the way out");

    // A build with no Black preset must simply not do this.
    SC::blanked = false; SC::restoreIdx = -1; SC::wantSwitch = false;
    SC::blackIdx = -2;
    g_blackIndex = -1;
    SC::lastPacketMs = g_millis;
    SC::noteFrame(frameWith(MINE));
    ok(!SC::consumePatternRequest(&idx),
       "a composition without the Black preset just leaves the pattern running");
    g_blackIndex = 3;
  }

  printf("\nstatus json\n");
  {
    String json;
    SC::appendStatus(json);
    std::string s = json.c_str();
    ok(s.rfind(",\"screencast\":{", 0) == 0,
       "status starts with a leading comma, as the hook asks");
    ok(s.back() == '}', "status is balanced");
    ok(s.find("\"port\":9002") != std::string::npos, "status reports the port");
  }

  printf("\n%d passed, %d failed\n", passed, failed);
  return failed == 0 ? 0 : 1;
}
