#pragma once
#include <Arduino.h>
// The tests drive handleDatagram() directly; this only has to compile.
struct WiFiUDP {
  void begin(uint16_t) {}
  int parsePacket() { return 0; }
  int read(uint8_t*, size_t) { return 0; }
  void flush() {}
};
