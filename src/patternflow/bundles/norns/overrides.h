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
// Bump this whenever the wire protocol or a diagnostic changes, so
// /api/status says which firmware is actually on the panel. The first hardware
// session lost time to exactly that: the only way to tell that a panel was a
// build behind was that a field it should have reported was missing.
//
//   v0.1.0  first build
//   v0.2.0  pixel-pair payload, /pf/scr/end double buffering, Black blanking,
//           screencast.rowdup in /api/status
//   v0.2.1  core v3.10.4: exact 300 Hz refresh, binary bit-plane chain,
//           white balance back to identity — the mirror looks different
//   v0.3.0  core v3.11.0: module code and data in PSRAM, so a pattern's size
//           no longer decides whether it loads (docs/06-hardware-findings.md);
//           parked modules come back instantly after the mirror; 19.5 dBm
//   v0.4.0  16 grey levels: pixel triples on the wire, the 8-level pairs of
//           older mods still accepted; screencast.levels in /api/status
//   v0.5.0  first public release: the edition is "norns-mirror" (was
//           "norns"), the mod "pf-mirror"; versioned together from here
#define PF_VARIANT "norns-mirror"
#define PF_VARIANT_VERSION "v0.5.0"

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

// ── A blank pattern for the mirror to stand behind ──────────────────────
//
// While the mirror is up, the running pattern still renders a full frame
// every frame and composeFrame then throws it away — invisible work that
// competes with the blit. The screencast feature asks for this preset when
// the mirror goes live and asks for the previous pattern back afterwards.
//
// Black is a core preset (features/show/preset_black.h) but nothing includes
// it unless a composition says so, twice: the include is taken inside
// feature_presets.h, and the entry expands inside the registry's preset
// table. PATTERN_ENTRY_HIDDEN keeps it out of the K4 browser — it is
// plumbing, not something to scroll past.
//
// The file depends only on core_canvas.h and core_encoders.h, so carrying it
// does not drag the show player in. Set PF_SCREENCAST_BLANK_PATTERN to 0 to
// leave the running pattern alone instead.
#define PF_FEATURE_PRESET_INCLUDE "show/preset_black.h"
#define PF_FEATURE_PRESETS PATTERN_ENTRY_HIDDEN(Black),

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
