// ═══════════════════════════════════════════════════════════
// feature: screencast — the norns screen on the panel
//
// Pairs with the norns system mod in src/norns/mod/patternflow/. The mod
// reads its own OLED with screen.peek and sends it here; this shows it, in a
// hue the panel's own knob 4 sets.
//
// It composes rather than overlays: while frames are arriving compose()
// returns the mirror, and the moment they stop it returns null and the
// running pattern comes straight back with nothing to reset. That is also
// why this never claims the pattern — the mirror is a view, not a mode.
//
// Hooks used: setup, onNetwork, loop, observeFrame, appendStatus,
// composeFrame, and the runtime toggle so the device's NETWORK screen can
// switch the mirror off without a reflash.
// Core edits: none.
//
// License: MIT
// ═══════════════════════════════════════════════════════════
#pragma once

#include "../pf_feature.h"
#include "core_screencast.h"

namespace PFFeatureScreencast {

inline void setup() { PatternflowScreencast::loadSettings(); }

inline void onNetwork() { PatternflowScreencast::begin(); }

// Drain the socket and latch the frame facts compose() can't see for itself.
// Both are O(1)-ish and neither blocks — the budget inside poll() is what
// bounds the worst case.
inline void loop(const PFFeatureFrame& frame) {
  PatternflowScreencast::noteFrame(frame);
  PatternflowScreencast::poll();
}

// The tint knob. Read-only, as observeFrame's contract asks: we watch the
// delta the pattern is about to see rather than consuming it. While the
// mirror is up the pattern is not on screen, so letting the same turn reach
// both costs nothing and keeps this out of fillInput, where it would be
// taking input away from a pattern that might be running.
inline void observeFrame(const InputFrame& input, const PFFeatureFrame&) {
#if PF_SCREENCAST_HUE_KNOB >= 1 && PF_SCREENCAST_HUE_KNOB <= 4
  if (!PatternflowScreencast::active()) return;
  PatternflowScreencast::nudgeHue(input.knobDeltas[PF_SCREENCAST_HUE_KNOB - 1]);
#else
  (void)input;
#endif
}

inline const uint8_t* composeFrame(const uint8_t* frame, int w, int h) {
  return PatternflowScreencast::compose(frame, w, h);
}

// Stand the running pattern down while the mirror is up: the pattern renders
// a full frame every frame that composeFrame then discards. We ask; loading a
// module is the sketch's job. Deliberately no claimsPattern — the mirror is a
// view, not a mode, and a host asking for a pattern should still win.
inline bool takePattern(int* idx) {
  return PatternflowScreencast::consumePatternRequest(idx);
}

inline void appendStatus(String& json) { PatternflowScreencast::appendStatus(json); }

inline bool isRuntimeEnabled() { return PatternflowScreencast::isRuntimeEnabled(); }
inline void setRuntimeEnabled(bool on) { PatternflowScreencast::setRuntimeEnabled(on); }

inline const PFFeature descriptor = {
    "screencast",
    "screencast",  // cap - a host can probe /api/status for this
    setup,
    onNetwork,
    loop,
    observeFrame,
    nullptr,       // fillInput
    nullptr,       // onUserInput
    nullptr,       // claimsPattern - the mirror is a view, never a mode
    takePattern,
    nullptr,       // onSleep
    nullptr,       // requestSleep
    "SCR",         // shortName - the device NETWORK screen row
    isRuntimeEnabled,
    setRuntimeEnabled,
    appendStatus,
    nullptr,       // drawOverlay - this feature composes instead
    nullptr,       // navPath - no console page yet
    nullptr,       // navLabel
    nullptr,       // navDesc
    composeFrame,
};

}  // namespace PFFeatureScreencast
