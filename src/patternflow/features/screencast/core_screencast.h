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

// One chunk of 1024 pixels plus address, typetag and two numeric args, padded.
// 1536 leaves room for a larger chunking scheme without another look at this.
constexpr size_t RX_CAP = 1536;

inline WiFiUDP udp;
inline bool ready = false;
inline bool runtimeEnabled = true;

inline uint8_t* levels = nullptr;   // SRC_PX, one 0-15 grey per pixel
inline uint8_t* scratch = nullptr;  // SRC_PX * 3, RGB888 handed to the core
inline uint8_t* rx = nullptr;       // RX_CAP

inline uint32_t lastPacketMs = 0;
inline uint32_t framesSeen = 0;
inline uint32_t chunksSeen = 0;
inline uint32_t dropped = 0;

// Tint. 0 = plain white (the honest monochrome mirror); turning right walks
// the hue circle. Kept as clicks so the knob has a repeatable home position.
inline int hueClicks = 0;
inline uint8_t palette[16][3];
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

  for (int lvl = 0; lvl < 16; lvl++) {
    const float v = (float)lvl / 15.0f;
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

inline int hexVal(uint8_t c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// ── The wire ─────────────────────────────────────────────────────────────
//
//   /pf/scr       ,ffs   chunk, nchunks, payload
//   /pf/scr/ping  (none)
//
// Every /pf/scr datagram is a complete statement about its own band of rows,
// so there is no reassembly and no sequence number: a lost packet costs those
// rows until they next change or the mod's periodic full refresh comes round.
// Chunk c covers pixels [c*px, (c+1)*px) where px = SRC_PX / nchunks, which
// for the mod's 8 chunks is 8 whole rows each.

inline bool handleDatagram(const uint8_t* buf, size_t len) {
  const char* addr;
  size_t pos;
  if (!oscString(buf, len, 0, &addr, &pos)) return false;

  if (strcmp(addr, "/pf/scr/ping") == 0) {
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
  if (strlen(payload) != px) return false;

  if (!levels) return false;
  uint8_t* dst = levels + (size_t)chunk * px;
  for (size_t i = 0; i < px; i++) {
    const int v = hexVal((uint8_t)payload[i]);
    if (v < 0) return false;  // malformed: leave the band as it was
    dst[i] = (uint8_t)v;
  }

  lastPacketMs = millis();
  chunksSeen++;
  if (chunk == 0) framesSeen++;
  return true;
}

// ── Socket ───────────────────────────────────────────────────────────────

inline void begin() {
  if (WiFi.status() != WL_CONNECTED) return;
  if (!levels) levels = (uint8_t*)PFMem::alloc(SRC_PX);
  if (!scratch) scratch = (uint8_t*)PFMem::alloc(SRC_PX * 3);
  if (!rx) rx = (uint8_t*)PFMem::alloc(RX_CAP);
  if (!levels || !scratch || !rx) {
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

inline void noteFrame(const PFFeatureFrame& f) {
  chromeUp = f.chromeVisible;
  running = f.running;
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
    const uint8_t* c = palette[src[i] & 0x0F];
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

inline void appendStatus(String& json) {
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
inline bool isRuntimeEnabled() { return false; }
inline void setRuntimeEnabled(bool) {}
inline void appendStatus(String&) {}
}  // namespace PatternflowScreencast

#endif
