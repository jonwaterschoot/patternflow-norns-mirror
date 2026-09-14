// ═══════════════════════════════════════════════════════════
// screencast — compile-time defaults
//
// Read only by a composition that carries features/screencast/. Every value
// is #ifndef-guarded, and patternflow_secrets.h (per device) and the
// composition's overrides.h (per edition) are included before this through
// config.h — so whatever they define wins and these fill in the rest. Same
// shape as features/osc/osc_config.h.
//
// License: MIT
// ═══════════════════════════════════════════════════════════
#pragma once
#include "../../config.h"

#ifndef PF_SCREENCAST_ENABLED
#define PF_SCREENCAST_ENABLED 1
#endif

// Its own socket, deliberately not the OSC feature's 9001. The OSC feature's
// receive buffer is 256 bytes and it drops anything larger, so a screen frame
// physically cannot travel there — see docs/01-verified-facts.md.
#ifndef PF_SCREENCAST_PORT
#define PF_SCREENCAST_PORT 9002
#endif

// How long after the last packet the mirror keeps the panel. The norns mod
// sends a keepalive four times a second even when the screen is static, so
// this only has to outlast a couple of missed ones.
#ifndef PF_SCREENCAST_TIMEOUT_MS
#define PF_SCREENCAST_TIMEOUT_MS 1200
#endif

// Datagrams drained per frame. The mod sends at most 8 (one per chunk) per
// norns redraw, so this clears a full frame plus a keepalive in one pass and
// still bounds the worst case if something floods the port. Same reasoning as
// PF_OSC_RX_BUDGET.
#ifndef PF_SCREENCAST_RX_BUDGET
#define PF_SCREENCAST_RX_BUDGET 12
#endif

// Which knob tints the mirror, 1-4, or 0 for none. Knob 4 by default: the
// norns mod leaves channel 4 unmapped for exactly this, and long-pressing
// encoder 4 is still the panel's own pattern switch.
#ifndef PF_SCREENCAST_HUE_KNOB
#define PF_SCREENCAST_HUE_KNOB 4
#endif

// Clicks of that knob for a full trip around the hue circle.
#ifndef PF_SCREENCAST_HUE_RANGE
#define PF_SCREENCAST_HUE_RANGE 96
#endif

// Stand the running pattern down while the mirror is up, by asking for the
// Black preset and asking for the previous pattern back afterwards.
//
// Without this the pattern underneath renders a full frame every frame that
// nobody ever sees — composeFrame replaces it — and competes with the blit
// for the loop. On by default, but it needs the composition to carry the
// Black preset: see the two PF_FEATURE_PRESET* defines in the bundle's
// overrides.h. With no Black in the build this quietly does nothing, so a
// composition that forgets them still runs.
#ifndef PF_SCREENCAST_BLANK_PATTERN
#define PF_SCREENCAST_BLANK_PATTERN 1
#endif
