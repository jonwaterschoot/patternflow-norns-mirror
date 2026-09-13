#pragma once
#include <Arduino.h>
namespace PFMem {
inline void* alloc(size_t bytes) { void* p = malloc(bytes); if (p) memset(p, 0, bytes); return p; }
}
