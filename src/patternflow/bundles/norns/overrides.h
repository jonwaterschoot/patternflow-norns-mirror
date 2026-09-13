// ═══════════════════════════════════════════════════════════
// Patternflow norns — settings this firmware changes.
//
// The core includes this from config.h before anything has a default, so any
// `#ifndef`-guarded value in config.h, net_config.h or a feature's
// <name>_config.h can be set here. No core file is edited.
//
// Keep the list short and keep the reasons attached. A setting with no stated
// reason is one nobody can safely change back.
// ═══════════════════════════════════════════════════════════
#pragma once

// ── What this firmware calls itself ─────────────────────────────────────
//
// Reported at /api/status and worn in the console header. Without it a panel
// running this claims to be core, and somebody who did not flash it has no
// way to find out what is actually on it — and the update banner would offer
// them a core release to install on top.
#define PF_VARIANT "norns"
#define PF_VARIANT_VERSION "v0.1.0"

// ── Where the panel's own OSC goes ──────────────────────────────────────
//
// This is the one setting the whole link depends on, and it is not obvious.
//
// The panel learns its remote from the first valid OSC packet it receives —
// but it learns the sender's IP *only*, and always replies to the
// compile-time PF_OSC_REMOTE_PORT. Meanwhile matron builds a fresh
// lo_address for every osc.send, so norns's packets leave from an ephemeral
// source port and never from 10111.
//
// Leave this at its 9000 default and the panel will learn the norns IP
// correctly and then send everything it has to a port nothing is listening
// on: the mirror would work and the encoders would appear dead. 10111 is
// matron's default receive port (matron/src/args.cc).
//
// PF_OSC_REMOTE_HOST is deliberately NOT set: the IP half of auto-learn is
// correct, and the norns mod pings on startup so there is always something
// to learn from. That keeps this firmware portable between norns units.
#define PF_OSC_REMOTE_PORT 10111

// ── The microphone stays off by default here ────────────────────────────
//
// The Audio edition turns this on because it is the edition built for a panel
// listening to a room. This one is built for a panel wired to a norns, where
// the sound worth reacting to is norns's own output and arrives over the
// network. Leaving the mic off means a knob the mirror is tinting cannot also
// be jittered by room noise.
//
// Set it to 1 if you want the panel to hear the room as well; nothing else
// has to change.
#define PF_AUDIO_IN_DRIVES_KNOBS 0
