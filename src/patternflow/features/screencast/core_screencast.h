// ═══════════════════════════════════════════════════════════
// screencast — receiving the norns screen, and painting it
//
// The norns `patternflow` mod reads its own 128x64 OLED with screen.peek and
// sends it here as hex text over UDP. This file owns the socket, the level
// buffer and the tint; feature_screencast.h is the hook wiring.
//
// Why a feature and not a pattern: a pattern module's ABI has no network.
// Why its own socket and not the OSC feature's: that feature's buffers are
// 256 bytes and it drops anything larger, so a frame physically cannot
// travel there.
//
// The design rule this obeys is the one written into the firmware after the
// GET /api/frame incident (docs/rest-api.md): nothing may capture the render
// loop. So the socket is drained non-blocking with a per-frame budget, and
// the composeFrame pass is a table lookup per pixel and nothing else.
//
// License: MIT
// ═══════════════════════════════════════════════════════════
#pragma once
#include "screencast_config.h"

#include <Arduino.h>

#include "../../src/core_mem.h"
#include "../pf_feature.h"

#if PF_SCREENCAST_ENABLED && PF_SCREENCAST_BLANK_PATTERN
// For findPatternByName, so the mirror can stand the running pattern down.
// show/, weather/ and mqtt/ reach it the same way.
#include "../../pattern_registry.h"
#endif

#if PF_SCREENCAST_ENABLED

#include <Preferences.h>
#include <WiFi.h>
#include <WiFiUdp.h>

namespace PatternflowScreencast {

// The norns screen, which is also this panel's geometry. The mirror is 1:1 or
// it does not run — scaling a 1-bit-ish UI is worse than not showing it.
constexpr int SRC_W = 128;
constexpr int SRC_H = 64;
constexpr size_t SRC_PX = (size_t)SRC_W * SRC_H;

// The largest datagram the mod sends is a 16-level chunk: 1366 characters
// plus address, typetag and two numeric args, 1392 bytes in all. 1536 holds
// it. The real ceiling is 1472, the UDP payload of a 1500-byte MTU: past that
// a datagram is fragmented, and fragments are a second way to lose a band.
constexpr size_t RX_CAP = 1536;

inline WiFiUDP udp;
inline bool ready = false;
inline bool runtimeEnabled = true;

// Double-buffered, and that is not an optimisation — it is what stops the
// panel showing a frame band by band. Chunks land in `pending`; only
// /pf/scr/end copies it to `levels`, which is the one compose() reads. The
// first hardware test showed frames visibly filling top to bottom without it.
//
// A copy rather than a pointer swap: unchanged bands are never re-sent, so
// `pending` has to keep carrying the last full picture. Swapping would leave
// the back buffer holding the frame before last, and any band that had not
// changed since would flick between the two. 8 KB per frame is nothing.
inline uint8_t* levels = nullptr;   // SRC_PX, one 0-15 grey per pixel, on show
inline uint8_t* pending = nullptr;  // SRC_PX, the frame being assembled
inline uint8_t* scratch = nullptr;  // SRC_PX * 3, RGB888 handed to the core
inline uint8_t* rx = nullptr;       // RX_CAP

inline uint32_t lastPacketMs = 0;
inline uint32_t framesSeen = 0;
inline uint32_t chunksSeen = 0;
inline uint32_t dropped = 0;
// Which encoding the last accepted chunk used, 8 or 16 (0 = none yet), so
// /api/status can say whether the mod on the other end is the new one.
inline uint8_t wireLevels = 0;

// Grey levels, as norns has them. Everything from the decoder on is in these
// 16. The 8-level pair encoding an older mod sends is widened on arrival
// (widen8()), so the palette and composeFrame have one scale to deal with.
constexpr int LEVELS = 16;

// Tint. 0 = plain white (the honest monochrome mirror); turning right walks
// the hue circle. Kept as clicks so the knob has a repeatable home position.
inline int hueClicks = 0;
inline uint8_t palette[LEVELS][3];
inline bool paletteStale = true;

// Frame facts, latched by the loop hook: composeFrame gets w/h but not
// whether the device's own UI is up. Same pattern the clock feature uses.
inline bool chromeUp = false;
inline bool running = true;

inline Preferences prefs;

// ── Palette ──────────────────────────────────────────────────────────────
//
// The whole cost of the tint is paid here, once per knob click: 16 entries,
// one per norns grey level. composeFrame then does a lookup per pixel and no
// arithmetic at all, which is what keeps a full 8 k-pixel pass comfortably
// inside its budget.

inline void buildPalette() {
  const bool white = (hueClicks <= 0);
  const float h = white ? 0.0f
                        : (float)((hueClicks - 1) % PF_SCREENCAST_HUE_RANGE) /
                              (float)(PF_SCREENCAST_HUE_RANGE > 1 ? PF_SCREENCAST_HUE_RANGE - 1 : 1);
  const float s = white ? 0.0f : 1.0f;

  for (int lvl = 0; lvl < LEVELS; lvl++) {
    const float v = (float)lvl / (float)(LEVELS - 1);
    float r = v, g = v, b = v;
    if (s > 0.0f) {
      const float hh = h * 6.0f;
      const int i = (int)hh % 6;
      const float f = hh - (float)((int)hh);
      const float p = v * (1.0f - s);
      const float q = v * (1.0f - s * f);
      const float t = v * (1.0f - s * (1.0f - f));
      switch (i) {
        case 0: r = v; g = t; b = p; break;
        case 1: r = q; g = v; b = p; break;
        case 2: r = p; g = v; b = t; break;
        case 3: r = p; g = q; b = v; break;
        case 4: r = t; g = p; b = v; break;
        default: r = v; g = p; b = q; break;
      }
    }
    palette[lvl][0] = (uint8_t)(r * 255.0f + 0.5f);
    palette[lvl][1] = (uint8_t)(g * 255.0f + 0.5f);
    palette[lvl][2] = (uint8_t)(b * 255.0f + 0.5f);
  }
  paletteStale = false;
}

inline void nudgeHue(int delta) {
  if (delta == 0) return;
  int next = hueClicks + delta;
  if (next < 0) next = 0;
  if (next > PF_SCREENCAST_HUE_RANGE) next = PF_SCREENCAST_HUE_RANGE;
  if (next != hueClicks) {
    hueClicks = next;
    paletteStale = true;
  }
}

// ── A very small OSC reader ──────────────────────────────────────────────
//
// Only what this wire needs: an address, a typetag, int/float scalars and one
// string. It is deliberately not a general parser — bundles, blobs and the
// rest would be dead code on a socket only the norns mod talks to.

inline size_t oscPad(size_t n) { return (n + 4u) & ~(size_t)3u; }

inline bool oscString(const uint8_t* buf, size_t len, size_t pos, const char** out, size_t* next) {
  if (pos >= len) return false;
  size_t end = pos;
  while (end < len && buf[end] != 0) end++;
  if (end >= len) return false;  // unterminated
  *out = (const char*)(buf + pos);
  *next = pos + oscPad(end - pos);
  return *next <= len;
}

inline bool oscInt32(const uint8_t* buf, size_t len, size_t pos, int32_t* out) {
  if (pos + 4 > len) return false;
  *out = (int32_t)(((uint32_t)buf[pos] << 24) | ((uint32_t)buf[pos + 1] << 16) |
                   ((uint32_t)buf[pos + 2] << 8) | (uint32_t)buf[pos + 3]);
  return true;
}

inline bool oscFloat32(const uint8_t* buf, size_t len, size_t pos, float* out) {
  int32_t bits;
  if (!oscInt32(buf, len, pos, &bits)) return false;
  memcpy(out, &bits, 4);
  return true;
}

// norns can only put floats on the wire: weaver's _osc_send marshals every
// Lua number with lo_message_add_float, so a chunk index arrives as 'f' and
// never as 'i'. Accepting both costs two lines and means a host that can send
// int32 (a desktop bridge, a test script) works without a second protocol.
inline bool oscNumber(const uint8_t* buf, size_t len, size_t pos, char type, long* out, size_t* next) {
  if (type == 'i') {
    int32_t v;
    if (!oscInt32(buf, len, pos, &v)) return false;
    *out = v;
    *next = pos + 4;
    return true;
  }
  if (type == 'f') {
    float v;
    if (!oscFloat32(buf, len, pos, &v)) return false;
    *out = (long)(v + (v < 0 ? -0.5f : 0.5f));
    *next = pos + 4;
    return true;
  }
  return false;
}

// The 64-character alphabet the mod packs pixel pairs into. Must match
// ALPHABET in mod.lua exactly, character for character.
inline const char* ALPHABET =
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+-";

inline int8_t symVal[256];
inline bool symReady = false;

inline void buildSymbolTable() {
  for (int i = 0; i < 256; i++) symVal[i] = -1;
  for (int i = 0; i < 64; i++) symVal[(uint8_t)ALPHABET[i]] = (int8_t)i;
  symReady = true;
}

// ── The wire ─────────────────────────────────────────────────────────────
//
//   /pf/scr       ,ffs   chunk, nchunks, payload
//   /pf/scr/end   (none)
//
// Each /pf/scr datagram is a complete statement about its own band of rows,
// so there is no reassembly and no sequence number: a lost packet costs those
// rows until they next change or the mod's periodic full refresh comes round.
// Chunk c covers pixels [c*px, (c+1)*px) where px = SRC_PX / nchunks, which
// for the mod's 4 chunks is 16 whole rows each.
//
// Two payload encodings, told apart by length alone:
//
//   16 levels  TWO characters per pixel TRIPLE: a*256 + b*16 + c is 12 bits,
//              high 6 then low 6 into ALPHABET. 16^3 == 64^2, so nothing is
//              wasted. A band is not a multiple of 3 pixels (2048 isn't), so
//              the mod pads it to the next triple and this ignores the pad:
//              2 * ceil(px / 3) characters, 1366 for a 2048-pixel band.
//   8 levels   one character per pixel PAIR: a*8 + b, 3-bit greys, px / 2
//              characters, 1024. What mods before the 16-level change send.
//              Still accepted, so the firmware can be flashed first.
//
// The two lengths never coincide for a band the checks allow.
//
// /pf/scr/end says the frame is complete — publish it — and doubles as the
// liveness beacon, which is why the mod sends it four times a second even
// when the screen has not changed.

// 0-7 onto 0-15 with both ends exact, rounded in between, so an old mod's
// picture comes out at the brightness it always had.
inline uint8_t widen8(int v) { return (uint8_t)((v * 15 + 3) / 7); }

inline void publishFrame() {
  if (!levels || !pending) return;
  memcpy(levels, pending, SRC_PX);
  framesSeen++;
}

inline bool handleDatagram(const uint8_t* buf, size_t len) {
  const char* addr;
  size_t pos;
  if (!oscString(buf, len, 0, &addr, &pos)) return false;

  if (strcmp(addr, "/pf/scr/end") == 0) {
    publishFrame();
    lastPacketMs = millis();
    return true;
  }
  if (strcmp(addr, "/pf/scr") != 0) return false;

  const char* types;
  if (!oscString(buf, len, pos, &types, &pos)) return false;
  if (types[0] != ',') return false;
  const char* t = types + 1;
  if (!t[0] || !t[1] || t[2] != 's') return false;

  long chunk = 0, nchunks = 0;
  if (!oscNumber(buf, len, pos, t[0], &chunk, &pos)) return false;
  if (!oscNumber(buf, len, pos, t[1], &nchunks, &pos)) return false;

  if (nchunks <= 0 || nchunks > 64) return false;
  if (SRC_PX % (size_t)nchunks) return false;
  const size_t px = SRC_PX / (size_t)nchunks;
  if (chunk < 0 || (size_t)chunk >= (size_t)nchunks) return false;

  const char* payload;
  size_t after;
  if (!oscString(buf, len, pos, &payload, &after)) return false;
  const size_t chars = strlen(payload);
  const bool triples = (chars == 2 * ((px + 2) / 3));
  // Pairs need an even band; a band that is not cannot be in that format.
  if (!triples && (px % 2 || chars != px / 2)) return false;

  if (!pending) return false;
  if (!symReady) buildSymbolTable();

  // Validate the whole payload before writing any of it. Bailing out mid-loop
  // left half a band of decoded pixels behind and the other half stale, which
  // is a worse outcome than dropping the packet — the band would sit torn
  // until something changed it.
  for (size_t i = 0; i < chars; i++) {
    if (symVal[(uint8_t)payload[i]] < 0) return false;
  }

  uint8_t* dst = pending + (size_t)chunk * px;
  if (triples) {
    // The last triple carries the pad. Writing it would land in the next
    // band, so the final group stops at px.
    for (size_t g = 0, p = 0; g < chars / 2; g++, p += 3) {
      const int v = symVal[(uint8_t)payload[g * 2]] * 64 + symVal[(uint8_t)payload[g * 2 + 1]];
      dst[p] = (uint8_t)(v >> 8);
      if (p + 1 < px) dst[p + 1] = (uint8_t)((v >> 4) & 15);
      if (p + 2 < px) dst[p + 2] = (uint8_t)(v & 15);
    }
    wireLevels = 16;
  } else {
    for (size_t i = 0; i < chars; i++) {
      const int v = symVal[(uint8_t)payload[i]];
      dst[i * 2] = widen8(v / 8);
      dst[i * 2 + 1] = widen8(v % 8);
    }
    wireLevels = 8;
  }

  lastPacketMs = millis();
  chunksSeen++;
  return true;
}

// ── Socket ───────────────────────────────────────────────────────────────

inline void begin() {
  if (WiFi.status() != WL_CONNECTED) return;
  if (!levels) levels = (uint8_t*)PFMem::alloc(SRC_PX);
  if (!pending) pending = (uint8_t*)PFMem::alloc(SRC_PX);
  if (!scratch) scratch = (uint8_t*)PFMem::alloc(SRC_PX * 3);
  if (!rx) rx = (uint8_t*)PFMem::alloc(RX_CAP);
  if (!levels || !pending || !scratch || !rx) {
    Serial.println("[SCR] out of memory; mirror disabled");
    return;
  }
  udp.begin(PF_SCREENCAST_PORT);
  ready = true;
  Serial.printf("[SCR] listening on :%d\n", PF_SCREENCAST_PORT);
}

// Bounded, non-blocking drain. Called from the per-frame hook, so the budget
// is what stops a flooding sender from turning into frame time.
inline void poll() {
  if (!ready || !runtimeEnabled) return;
  for (int i = 0; i < PF_SCREENCAST_RX_BUDGET; i++) {
    const int size = udp.parsePacket();
    if (size <= 0) return;
    if (size > (int)RX_CAP) {
      udp.flush();
      dropped++;
      continue;
    }
    const int n = udp.read(rx, RX_CAP);
    if (n <= 0) continue;
    if (!handleDatagram(rx, (size_t)n)) dropped++;
  }
}

inline bool active() {
  return ready && runtimeEnabled && lastPacketMs != 0 &&
         (millis() - lastPacketMs) < PF_SCREENCAST_TIMEOUT_MS;
}

// ── Standing the pattern down while the mirror is up ─────────────────────
//
// The pattern underneath keeps running while we mirror: its update() and
// draw() cost a full frame's work every frame, and then composeFrame throws
// the result away. Nobody sees it and it competes with the blit for the loop.
//
// So while the mirror is live we ask for the Black preset — a compiled-in
// pattern whose draw() clears and presents — and ask for the previous one
// back when the mirror stops. Requesting is all a feature may do: loading a
// module is the sketch's job, which is what takePattern is for.
//
// This never *claims* the pattern. The mirror is a view, not a mode, and a
// host that wants a different pattern while mirroring should still win.

inline bool wantSwitch = false;
inline int wantIdx = -1;
inline int restoreIdx = -1;   // what was running before we blanked it
inline bool blanked = false;
inline int blackIdx = -2;     // -2 = not looked up yet, -1 = not present

inline void updateBlanking(int currentIdx) {
#if PF_SCREENCAST_BLANK_PATTERN
  if (blackIdx == -2) blackIdx = findPatternByName("Black");
  if (blackIdx < 0) return;   // this build carries no Black preset

  const bool live = active() && !chromeUp;
  if (live && !blanked) {
    if (currentIdx == blackIdx) return;  // already there; nothing to restore
    restoreIdx = currentIdx;
    wantIdx = blackIdx;
    wantSwitch = true;
    blanked = true;
  } else if (!live && blanked) {
    blanked = false;
    // Only put it back if nothing else moved the pattern meanwhile — if a
    // host or a hand chose something while we were mirroring, that choice
    // is newer than ours and outranks it.
    if (restoreIdx >= 0 && currentIdx == blackIdx) {
      wantIdx = restoreIdx;
      wantSwitch = true;
    }
    restoreIdx = -1;
  }
#else
  (void)currentIdx;
#endif
}

inline bool consumePatternRequest(int* idx) {
  if (!wantSwitch) return false;
  wantSwitch = false;
  *idx = wantIdx;
  return true;
}

inline void noteFrame(const PFFeatureFrame& f) {
  chromeUp = f.chromeVisible;
  running = f.running;
  updateBlanking(f.patternIndex);
}

// ── The hook ─────────────────────────────────────────────────────────────

inline const uint8_t* compose(const uint8_t* canvas, int w, int h) {
  (void)canvas;  // the mirror replaces the frame; it does not blend with it
  if (!active() || chromeUp) return nullptr;
  if (w != SRC_W || h != SRC_H) return nullptr;  // 1:1 or not at all
  if (!levels || !scratch) return nullptr;
  if (paletteStale) buildPalette();

  const uint8_t* src = levels;
  uint8_t* dst = scratch;
  for (size_t i = 0; i < SRC_PX; i++, dst += 3) {
    const uint8_t* c = palette[src[i] & (LEVELS - 1)];
    dst[0] = c[0];
    dst[1] = c[1];
    dst[2] = c[2];
  }
  return scratch;
}

// ── Runtime toggle, so the device's own NETWORK screen can switch it off ──

inline void loadSettings() {
  if (prefs.begin("pf-scr", true)) {
    runtimeEnabled = prefs.getBool("on", true);
    hueClicks = prefs.getInt("hue", 0);
    prefs.end();
  }
  paletteStale = true;
}

inline void saveSettings() {
  if (prefs.begin("pf-scr", false)) {
    prefs.putBool("on", runtimeEnabled);
    prefs.putInt("hue", hueClicks);
    prefs.end();
  }
}

inline bool isRuntimeEnabled() { return runtimeEnabled; }
inline void setRuntimeEnabled(bool on) {
  runtimeEnabled = on;
  saveSettings();
}

// How many adjacent row pairs are byte-identical in the buffer about to be
// drawn, and the first such row. This exists to settle one question: when the
// panel shows a row twice, did it arrive twice?
//
// Point the mod's `rows` test card at it — alternate rows lit, so no two
// neighbours can be equal — and read this back. Zero here with visible
// doubling on the panel means the data is right and the doubling happened
// downstream, in the blit or the panel itself. Non-zero means it is ours.
//
// 63 comparisons of 128 bytes, only when somebody asks for /api/status.
inline void rowDupStats(int* count, int* first) {
  *count = 0;
  *first = -1;
  if (!levels) return;
  for (int y = 0; y + 1 < SRC_H; y++) {
    if (memcmp(levels + (size_t)y * SRC_W, levels + (size_t)(y + 1) * SRC_W,
               SRC_W) == 0) {
      if (*first < 0) *first = y;
      (*count)++;
    }
  }
}

inline void appendStatus(String& json) {
  int dupCount, dupFirst;
  rowDupStats(&dupCount, &dupFirst);
  json += ",\"screencast\":{\"on\":";
  json += runtimeEnabled ? "true" : "false";
  json += ",\"live\":";
  json += active() ? "true" : "false";
  json += ",\"port\":";
  json += (int)PF_SCREENCAST_PORT;
  json += ",\"hue\":";
  json += hueClicks;
  json += ",\"frames\":";
  json += framesSeen;
  json += ",\"chunks\":";
  json += chunksSeen;
  json += ",\"dropped\":";
  json += dropped;
  json += ",\"levels\":";
  json += (int)wireLevels;
  json += ",\"rowdup\":";
  json += dupCount;
  json += ",\"rowdupfirst\":";
  json += dupFirst;
  json += "}";
}

}  // namespace PatternflowScreencast

#else  // !PF_SCREENCAST_ENABLED

namespace PatternflowScreencast {
inline void begin() {}
inline void poll() {}
inline bool active() { return false; }
inline void noteFrame(const PFFeatureFrame&) {}
inline const uint8_t* compose(const uint8_t*, int, int) { return nullptr; }
inline void loadSettings() {}
inline void nudgeHue(int) {}
inline bool consumePatternRequest(int*) { return false; }
inline bool isRuntimeEnabled() { return false; }
inline void setRuntimeEnabled(bool) {}
inline void appendStatus(String&) {}
}  // namespace PatternflowScreencast

#endif
