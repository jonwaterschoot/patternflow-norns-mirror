// Just enough Arduino to compile features/screencast/ on a desktop.
// Nothing here is a model of the real thing — it exists so the OSC parser,
// the hex decode and the palette can be tested without an ESP32 attached.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>

extern unsigned long g_millis;
inline unsigned long millis() { return g_millis; }

struct String {
  std::string s;
  String() {}
  String(const char* p) : s(p ? p : "") {}
  String& operator+=(const char* p) { s += p ? p : ""; return *this; }
  String& operator+=(char c) { s += c; return *this; }
  String& operator+=(int v) { s += std::to_string(v); return *this; }
  String& operator+=(long v) { s += std::to_string(v); return *this; }
  String& operator+=(unsigned v) { s += std::to_string(v); return *this; }
  String& operator+=(unsigned long v) { s += std::to_string(v); return *this; }
  const char* c_str() const { return s.c_str(); }
};

struct SerialStub {
  void printf(const char*, ...) {}
  void println(const char*) {}
};
inline SerialStub Serial;
