#pragma once
#include <Arduino.h>
struct Preferences {
  bool begin(const char*, bool = false) { return false; }
  void end() {}
  bool getBool(const char*, bool d) { return d; }
  int getInt(const char*, int d) { return d; }
  void putBool(const char*, bool) {}
  void putInt(const char*, int) {}
};
