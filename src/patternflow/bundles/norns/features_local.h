// ═══════════════════════════════════════════════════════════
// Patternflow norns — what this firmware is, in one file.
//
// The Audio edition, plus the screen mirror. Nothing is dropped: a panel
// flashed with this still does everything the Audio firmware did, so pairing
// it with norns costs none of the DAW, browser-audio or microphone paths.
//
//   osc         How norns drives the panel and the panel drives norns. Both
//               directions are stock — the panel already sends knob and
//               button events, and norns already answers /remote/enc. The
//               translation between the two vocabularies lives on norns, in
//               the mod, not here.
//   screencast  Ours. Receives the norns OLED over UDP and shows it.
//   audio       The browser path and its WebSocket.
//   audio_in    The on-board PDM microphone.
//   midi        RTP-MIDI, for the same reason OSC is here.
//
// Order is dispatch order, and here it matters twice:
//
//   OSC first, because it only ASKS for a pattern; anything that CLAIMS one
//   would starve it.
//
//   screencast second, because composeFrame is CHAINED — each feature is
//   handed what the one before produced. The mirror replaces the frame
//   outright, so any decorative composer (a clock, a banner) has to come
//   after it to land on top of the mirror instead of being wiped by it.
//
// This file is not a core file and neither is overrides.h beside it. Nothing
// in the vendored core tree is edited, which is why taking an upstream update
// is `git -C vendor/patternflow checkout <newer tag>` and nothing else.
// ═══════════════════════════════════════════════════════════
#pragma once

#include "osc/feature_osc.h"
#include "screencast/feature_screencast.h"
#include "audio/feature_audio.h"
#include "audio_in/feature_audio_in.h"
#include "midi/feature_midi.h"

#define PF_FEATURE_LIST                  \
    &PFFeatureOsc::descriptor,           \
    &PFFeatureScreencast::descriptor,    \
    &PFFeatureAudio::descriptor,         \
    &PFFeatureAudioIn::descriptor,       \
    &PFFeatureMidi::descriptor
