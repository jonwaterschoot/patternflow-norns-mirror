# Archive

The notes from the planning session that preceded the code, kept verbatim.
They were written from recall rather than from the source, and a later pass
read both codebases and checked every load-bearing claim. Most held. Several
did not.

Nothing here should be used as a reference. It is kept because the reasoning
is still worth reading and because it records what we believed before we
looked.

| file | superseded by |
|---|---|
| `README-original.md` | [`../../README.md`](../../README.md) and [`../01-verified-facts.md`](../01-verified-facts.md) |
| `00-prior-art.md` | [`../05-prior-art.md`](../05-prior-art.md) |
| `07-roadmap.md` | [`../04-roadmap.md`](../04-roadmap.md) |
| `08-architecture.md` | [`../03-architecture.md`](../03-architecture.md) |
| `09-interaction-expansions.md` | [`../04-roadmap.md`](../04-roadmap.md) M4–M6 |
| `screencast-README-original.md` | [`../02-wire-protocol.md`](../02-wire-protocol.md) and the feature source |

Docs 01–06 are referenced by the original README's file map but never existed;
the session that wrote these produced only the files here.

## What the source review changed

- **We are not forking Patternflow.** Upstream documents and CI-enforces an
  out-of-tree composition. The archived notes assumed a fork throughout.
- **`composeFrame` exists.** The archived notes describe a vague "per-frame
  draw hook" and a feature that blits over the panel. The real hook composes
  *before* the blit and yields the panel back by returning null, which is both
  cleaner and cheaper than what was planned.
- **Audio lanes need no new OSC route.** They are `knobAudioValue[]` in
  `InputFrame`, written from a `fillInput` hook. The archived plan proposed
  adding `/pf/lane/N` to the firmware.
- **norns cannot send OSC blobs**, and every Lua number goes out as a float32.
  The archived notes left this as an open question with base64 as a fallback;
  it is not a fallback, it is the only option, and the float detail was missed
  entirely.
- **norns already answers `/remote/enc` and `/remote/key`.** This was not in
  the archived notes at all, and it is the single biggest change: driving norns
  from the panel is the *cheapest* thing in the project, not a later milestone.
  It reordered the roadmap.
- **`screencast-README-original.md` contradicts `README-original.md`** on
  whether norns can read its own framebuffer. The README was right —
  `screen.peek` is stock. The screencast note's closing paragraph is wrong.
- **`PF_OSC_REMOTE_PORT 10111` was right**, and is now understood rather than
  asserted: the panel's auto-learn captures the sender's IP only and always
  replies to the compile-time port, while norns sends from an ephemeral one.
