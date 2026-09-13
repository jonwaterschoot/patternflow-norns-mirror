# Working in this repo

Read [`docs/01-verified-facts.md`](docs/01-verified-facts.md) before changing
anything load-bearing. It is the reference the code and the other docs are
written against, every claim in it was read out of the vendored source rather
than recalled, and each one carries the file it came from. If you change a fact
there, change it there *first*.

## Ground rules

**Never edit anything under `vendor/`.** All three are submodules and
`vendor/patternflow` in particular must stay byte-identical to upstream — that
is the entire reason taking an update is a `git checkout` with nothing to
merge. `tools/build-firmware.sh` copies our files in, builds, and removes them
again; `git -C vendor/patternflow status` should always be empty. Upstream's
`check_boundaries.py` runs on every build and will fail if a core file ever
learns a feature's name.

**Verify against the vendored source, not from memory.** Both upstream trees
are checked out locally, so there is no reason to guess at an API. This
codebase already has one archived generation of notes that were written from
recall; roughly a third of the load-bearing claims in them were wrong, and
[`docs/archive/README.md`](docs/archive/README.md) lists which.

**Run the tests.** They are fast and they cover the parts that are easy to get
subtly wrong:

```bash
python tools/run_lua_tests.py    # the mod, against stubbed norns globals
bash tools/hosttest/run.sh       # the real feature, compiled and driven on the desktop
bash tools/build-firmware.sh     # builds, and scans the image for its composition
python tools/check_docs.py       # every relative link and #anchor resolves
```

## Things that will bite you

- **The `PFFeature` descriptor is a positional aggregate initializer.**
  Upstream's own header warns that adjacent same-typed fields reorder without
  any compiler diagnostic — the build stays green and hooks silently wire to
  the wrong functions. `tools/hosttest/gen_stub.py` lifts the struct verbatim
  from the vendored core so the host test provides that missing diagnostic.
  After bumping the submodule, run the host test before anything else.
- **norns marshals every Lua number as a float32** and cannot send blobs. Any
  new message in either direction has to survive that.
- **`Screen.update` gets reassigned** by the screensaver and by `Screen.ping`.
  Wrap `Screen.update_default` instead — a wrapper on `update` is silently
  discarded the first time the screen sleeps.
- **`composeFrame` is chained**, in feature list order, each feature receiving
  what the previous produced. `screencast` replaces the frame outright, so
  anything decorative has to be listed *after* it to appear on top.
- **The frame hooks must not block.** No `delay()`, no blocking socket reads,
  and a full pass over the frame has to stay well under a millisecond. The
  socket drain is budgeted for the same reason.

## Style

Match what is already here. The two upstream projects both write comments that
explain *why* a thing is the way it is — usually naming the incident that
caused it — and the code in `src/` follows that. A comment that restates what
the next line does is noise; one that records a constraint the code cannot show
is the whole point.
