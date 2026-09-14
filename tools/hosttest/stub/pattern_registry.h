// Stub of the core's pattern registry — only findPatternByName, which is all
// the screencast feature uses (to locate the Black preset it stands the
// running pattern down to).
//
// The test controls what it returns, so the blanking logic can be driven
// through both the "this build carries Black" and "it does not" paths.
#pragma once
#include <Arduino.h>

inline int g_blackIndex = 3;   // the test sets this; -1 means "not in the build"

inline int findPatternByName(const char* name) {
  if (name && strcmp(name, "Black") == 0) return g_blackIndex;
  return -1;
}
