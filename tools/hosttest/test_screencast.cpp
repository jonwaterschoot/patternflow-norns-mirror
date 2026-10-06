// Host test for features/screencast/.
//
// Compiles the real feature sources against generated stubs and drives them
// with byte-exact OSC datagrams — built the way liblo builds them, which is
// to say with every number as a big-endian float32, because that is all
// norns can put on the wire.
//
// What this is actually protecting:
//   - the OSC reader, which is hand-rolled and full of offsets
//   - the pixel packing, triples and the older pairs, where swapping two
//     slots would be a plausible-looking picture with every column wrong
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

// 16 levels: TWO characters encode a pixel TRIPLE, a*256 + b*16 + c, high
// six bits first. A band is padded up to whole triples.
static std::string tri(int a, int b, int c) {
  const int v = a * 256 + b * 16 + c;
  return std::string{SC::ALPHABET[v / 64], SC::ALPHABET[v % 64]};
}
static size_t triChars(size_t px) { return 2 * ((px + 2) / 3); }
static std::string fill16(int lvl, size_t px) {
  std::string out;
  for (size_t g = 0; g < (px + 2) / 3; g++) out += tri(lvl, lvl, lvl);
  return out;
}

// 8 levels, what older mods send: one character is a PIXEL PAIR, a*8 + b.
static char sym8(int a, int b) { return SC::ALPHABET[a * 8 + b]; }
static std::string pairRun(int a, int b, size_t chars) {
  return std::string(chars, sym8(a, b));
}

int main() {
  // begin() needs Wi-Fi and a socket; allocate the buffers directly instead.
  SC::levels = (uint8_t*)PFMem::alloc(SC::SRC_PX);
  SC::pending = (uint8_t*)PFMem::alloc(SC::SRC_PX);
  SC::scratch = (uint8_t*)PFMem::alloc(SC::SRC_PX * 3);
  SC::ready = true;
  SC::runtimeEnabled = true;

  const size_t px = SC::SRC_PX / 4;   // 2048 pixels per chunk
  const size_t chars = triChars(px);  // 1366 characters: 683 triples, one pad
  const size_t chars8 = px / 2;       // 1024, the older pair encoding

  printf("wire format, 16 levels\n");
  ok(chars == 1366, "a 2048-pixel band is 1366 characters");
  ok(feed(frameMsg(0, 4, fill16(15, px))), "a well-formed chunk 0 is accepted");
  ok(SC::wireLevels == 16, "and status says the mod is sending 16 levels");
  ok(SC::pending[0] == 15 && SC::pending[1] == 15 && SC::pending[2] == 15,
     "two characters decode to three pixels");
  ok(SC::pending[px - 1] == 15, "the whole band is written, to its last pixel");
  ok(SC::pending[px] == 0, "and the pad does not spill into the next band");

  ok(feed(frameMsg(3, 4, fill16(9, px))), "the last chunk is accepted");
  ok(SC::pending[SC::SRC_PX - 1] == 9, "the last pixel of the panel is written");

  {
    std::string one = tri(1, 2, 3) + fill16(0, px).substr(2);
    ok(feed(frameMsg(1, 4, one, /*asInt=*/true)), "int32-typed args also work");
    ok(SC::pending[px] == 1 && SC::pending[px + 1] == 2 && SC::pending[px + 2] == 3,
       "the three slots of a triple are in order");
  }

  {
    // Every level through every slot, across the whole band, including the
    // last triple whose third slot is the pad.
    std::vector<uint8_t> want(px);
    for (size_t i = 0; i < px; i++) want[i] = (uint8_t)((i * 7 + i / 3) % 16);
    std::string enc;
    for (size_t p = 0; p < px; p += 3) {
      enc += tri(want[p], p + 1 < px ? want[p + 1] : 0, p + 2 < px ? want[p + 2] : 0);
    }
    ok(feed(frameMsg(2, 4, enc)), "a chunk using every level is accepted");
    ok(memcmp(SC::pending + 2 * px, want.data(), px) == 0,
       "every level 0-15 round-trips in every slot of the triple");
  }

  printf("\nwire format, 8 levels from an older mod\n");
  ok(feed(frameMsg(0, 4, pairRun(7, 7, chars8))), "a 1024-character chunk is still accepted");
  ok(SC::wireLevels == 8, "and status says the mod is the old one");
  ok(SC::pending[0] == 15 && SC::pending[px - 1] == 15, "its top level is the top level");
  ok(feed(frameMsg(1, 4, pairRun(2, 5, chars8))), "a mixed pair is accepted");
  ok(SC::pending[px] == 4 && SC::pending[px + 1] == 11,
     "the halves are not swapped, and 0-7 is widened onto 0-15");
  ok(feed(frameMsg(1, 4, pairRun(0, 4, chars8))) && SC::pending[px] == 0 &&
         SC::pending[px + 1] == 9,
     "black stays black, and the middle lands in the middle");

  printf("\ndouble buffering — the fix for banded tearing\n");
  {
    memset(SC::levels, 0, SC::SRC_PX);
    memset(SC::pending, 0, SC::SRC_PX);
    ok(feed(frameMsg(0, 4, fill16(15, px))), "a chunk arrives");
    ok(SC::levels[0] == 0, "and is NOT shown yet — no half-drawn frame reaches the panel");
    ok(SC::pending[0] == 15, "it waits in the back buffer");
    ok(feed(endMsg()), "the frame-complete marker is accepted");
    ok(SC::levels[0] == 15, "which publishes the whole frame at once");

    ok(feed(frameMsg(1, 4, fill16(3, px))), "a later frame changes one band");
    ok(feed(endMsg()), "and completes");
    ok(SC::levels[0] == 15, "the band that did not change is still there");
    ok(SC::levels[px] == 3, "the band that did is updated");
  }

  printf("\nkeepalive and liveness\n");
  g_millis = 5000;
  ok(feed(frameMsg(0, 4, fill16(15, px))), "a frame refreshes liveness");
  ok(SC::active(), "the mirror is active right after a packet");
  g_millis = 5000 + PF_SCREENCAST_TIMEOUT_MS + 1;
  ok(!SC::active(), "the mirror goes idle after the timeout");
  ok(feed(endMsg()), "the frame-complete marker alone is accepted");
  ok(SC::active(), "and keeps the mirror up — this is the idle-screen keepalive");

  printf("\nmalformed input is refused, not obeyed\n");
  {
    memset(SC::pending, 1, SC::SRC_PX);
    std::string bad = fill16(15, px);
    bad[chars - 1] = '~';   // not in the alphabet
    ok(!feed(frameMsg(0, 4, bad)), "a symbol outside the alphabet is rejected");
    bool untouched = true;
    for (size_t i = 0; i < px; i++) if (SC::pending[i] != 1) untouched = false;
    ok(untouched, "and not one pixel was written before the refusal");

    std::string bad8 = pairRun(7, 7, chars8);
    bad8[0] = '~';
    ok(!feed(frameMsg(0, 4, bad8)), "the same goes for the older encoding");

    ok(!feed(frameMsg(0, 4, fill16(15, px).substr(1))), "a short payload is rejected");
    ok(!feed(frameMsg(0, 4, fill16(15, px) + "0")), "a long payload is rejected");
    ok(!feed(frameMsg(0, 4, pairRun(7, 7, chars8 + 1))),
       "a length that is neither encoding is rejected");
    ok(!feed(frameMsg(4, 4, fill16(15, px))), "an out-of-range chunk index is rejected");
    ok(!feed(frameMsg(-1, 4, fill16(15, px))), "a negative chunk index is rejected");
    ok(!feed(frameMsg(0, 3, fill16(15, px))),
       "an nchunks that does not divide the panel is rejected");
    ok(!feed(frameMsg(0, 0, fill16(15, px))),
       "nchunks of zero is rejected (no divide by zero)");
    ok(!feed(frameMsg(0, 999, fill16(15, px))), "an absurd nchunks is rejected");

    std::vector<uint8_t> other;
    pushStr(other, "/patternflow/knob/1/delta");
    pushStr(other, ",f");
    pushF32(other, 1.0f);
    ok(!feed(other), "an unrelated OSC address is ignored");

    // Truncation at every length must not read past the end. Under a
    // sanitizer a single overrun here fails the run.
    std::vector<uint8_t> full = frameMsg(0, 4, fill16(15, px));
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
    ok(feed(frameMsg(5, 8, fill16(6, px8))), "an 8-chunk frame is accepted");
    ok(SC::pending[5 * px8] == 6 && SC::pending[6 * px8 - 1] == 6,
       "chunk 5 of 8 covers exactly its own band");
    ok(SC::pending[5 * px8 - 1] == 0, "nothing before it");
    ok(SC::pending[6 * px8] == 0, "and nothing after it — no bleed into the next band");
  }

  printf("\ncompose\n");
  {
    memset(SC::levels, 0, SC::SRC_PX);
    SC::levels[0] = 15;  // full white
    SC::levels[1] = 0;   // black
    SC::levels[2] = 8;   // mid
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

  printf("\nrow-duplication diagnostic\n");
  {
    int count = -1, first = -1;

    // The `rows` test card: alternate rows lit. No two neighbours can be
    // equal, so this must find nothing — which is what makes it able to prove
    // that doubling seen on the panel happened after the data arrived.
    for (int y = 0; y < SC::SRC_H; y++) {
      memset(SC::levels + (size_t)y * SC::SRC_W, (y % 2) ? 0 : 15, SC::SRC_W);
    }
    SC::rowDupStats(&count, &first);
    ok(count == 0, "alternating rows report no duplicate pairs");
    ok(first == -1, "and no first-duplicate row");

    // Genuinely duplicate one row and it has to be found, at the right index.
    // The base is y % 8 rather than the alternating card: copying row 5 over
    // row 6 there would also make 6 match 7, and the test would be asserting
    // on two duplicate pairs while claiming to make one.
    for (int y = 0; y < SC::SRC_H; y++) {
      memset(SC::levels + (size_t)y * SC::SRC_W, y % 8, SC::SRC_W);
    }
    SC::rowDupStats(&count, &first);
    ok(count == 0, "a ramp with no equal neighbours reports none");
    memcpy(SC::levels + 6 * SC::SRC_W, SC::levels + 5 * SC::SRC_W, SC::SRC_W);
    SC::rowDupStats(&count, &first);
    ok(count == 1, "a duplicated row is counted");
    ok(first == 5, "and reported at the first row of the pair");

    // An all-black screen is 63 identical pairs, which is correct, not a fault.
    memset(SC::levels, 0, SC::SRC_PX);
    SC::rowDupStats(&count, &first);
    ok(count == SC::SRC_H - 1, "a blank screen is all-duplicate, as it should be");
    ok(first == 0, "starting at row 0");
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
    ok(s.find("\"levels\":") != std::string::npos,
       "and which encoding the mod is sending");
  }

  printf("\n%d passed, %d failed\n", passed, failed);
  return failed == 0 ? 0 : 1;
}
