# Slice 1 Spec — Timed Capture (always-anchoring engine)

**Status: SPEC — decisions locked, ready to implement slice 1.**
**Scope:** add per-buffer capture timestamps to `multichannel_capture` as a
first-class capability. One capture engine that always anchors; timed and untimed
reads are equal peer views over one shared PCM ring. **Working tree only — no
commit. Hand back for a read before any code.** Design against the audited code,
not the README.

---

## Identity (this is not a bolt-on)

The engine **always** timestamps. `frames` / `mc_read_frames` (untimed) and
`timedFrames` / `mc_read_frames_timed` (timed) are two peer readers over the same
PCM ring — not a base path plus an addition. The untimed path is byte-for-byte
what ships today; timing is a side-channel the untimed reader never consults.

## Approach — Path B (locked, do not reopen)

- Sample `mach_absolute_time()` at the **top of `mc_capture_data_callback`** (a
  commpage read, no syscall). Write one anchor `(firstFrameIndex, hostTime)` to a
  preallocated circular array with a release store. That is the entire addition to
  the callback.
- **The anchor's index is cumulative frames *written to the ring* (post-drop) — not
  frames the device delivered (pre-drop).** They are the same number *only* because
  the ring is lossless FIFO: every committed frame drains in order and drops happen
  before the index advances, so the write-side anchor index equals the drain-side
  `firstFrameIndex`. Advance the cumulative counter by frames **committed**, never by
  the callback's `frameCount`; a captured-count anchor would diverge from the
  delivered index by exactly `droppedFrames` and misplace all audio after a gap —
  passing clean capture, failing only under drops.
- **Emit an anchor only when the callback commits ≥1 frame** (stamp the first
  committed frame's index). A fully-dropped callback (ring full, zero committed) must
  **not** publish an anchor — otherwise sustained overflow yields multiple anchors
  sharing one `frameIndex`, and interpolation degenerates (ambiguous bracket /
  divide-by-zero on `a1.frameIndex − a0.frameIndex`). This keeps anchor `frameIndex`
  strictly increasing, and it is exercised precisely under the Leg 2 stall.
- **No `miniaudio.h` patch.** Grabbing exact CoreAudio `mHostTime` would mean
  forking a vendored header and re-applying every bump. Declined. This is our own C
  only — no fork, no upstream PR.
- Same mach host timebase as AVFoundation video PTS (`CMClockGetHostTimeClock`).
  Bias is a constant callback-dispatch latency, **non-accumulating**.

## Decision — always anchor, never gate

The engine anchors on every callback, unconditionally. **Do not** add a "did
someone ask for timing?" gate.

> **Reason to record:** the engine's behavior must not depend on who's consuming
> it. A gate would read consumer state on the audio thread and make the pump behave
> differently depending on whether a timed reader is attached — a heisenbug source
> strictly worse than the two unconditional stores it would save. (The stores being
> negligible is *why it's free*; consumer-independence is *why it's right*.)

## Decision — untimed does not delegate to timed (2b declined)

`mc_read_frames` reads the shared PCM ring **directly**. It must **not** be
reimplemented to call `mc_read_frames_timed` and discard the timing.

> **Reason to record:** delegating would route the proven pump drain path through
> interpolation it throws away, for ~10 lines of dedup and zero functional gain. The
> two drain loops staying separate is deliberate. Anyone later "tidying" this into
> one path is reintroducing risk to the load-bearing pump path — don't.

## Additive — break nothing

The untimed **data path** is unchanged: `frames` still drains via `mc_read_frames`,
and `startCapture({int? deviceIndex, int sampleRate, int channels})` keeps its
signature. The Agora call pump consumes the untimed path and keeps working. The
delta to its world is the two stores added to the shared callback — plus one
deliberate refinement: draining now starts at **first listen** (not before), so the
shared single-consumer ring has exactly one clean origin and the untimed and timed
delivered-indices can never desync. Reader mode is claimed at the getter and the
conflicting view throws a `StateError` **synchronously** at the call site — the two
views are loudly mutually exclusive, not convention-only.

---

## New surface (names locked)

**Native**
- `mc_read_frames_timed` — reads the same PCM ring as `mc_read_frames`, plus
  interpolates each drained frame's host time from the anchor ring.
- `mc_capture_dropped_frames` — monotonic counter of frames the device produced but
  the ring couldn't accept.

**Dart**
- `timedFrames` — stream peer to `frames` (the `frames`→`timedFrames` symmetry is
  intentional).
- `TimedAudioBatch { samples, hostTime, firstFrameIndex }`
- `droppedFrames`

**`hostTime` is raw mach host-time units — not nanoseconds.** Doc comment on the
field: *"Raw mach host-time units. Feed `CMClockMakeHostTimeFromSystemUnits`; do not
assume nanoseconds."*

> **Why raw units, not ns (the genuinely-chosen bet):** both sides — CoreAudio
> capture time and AVFoundation video PTS — natively live in the host clock's raw
> units, and the canonical bridge `CMClockMakeHostTimeFromSystemUnits` consumes raw
> units, zero arithmetic. That representational unity is the real reason: keep raw
> units and audio and video share one representation through one CoreMedia call,
> with no conversion code where a `ticks == ns` assumption could hide. (That
> assumption is the actual footgun — `mach_absolute_time()` equals nanoseconds only
> where the mach timebase is 1/1, which is platform-dependent and **not** guaranteed;
> Apple Silicon's timebase is not 1/1. Correctly *converted* ns would be portable,
> so this is a unity-and-idiom win, not a safety one.) This commits the package's
> value to CoreMedia semantics; acceptable because it's a CoreMedia-feeding package,
> and it's **additive-reversible** — a `hostTimeNs` accessor is a later addition if a
> non-Apple consumer ever appears, never a rip-out.

## delivered-vs-dropped contract

- **`firstFrameIndex`** — cumulative count of frames **delivered** to this stream.
  Monotonic, continuous, **never skips**. A drop puts no hole in it. This is what
  makes it usable as a muxer audio-input sequence number: gaps live in the PTS,
  never in the index.
- **`droppedFrames`** — separate monotonic counter of overflow casualties.
- **`hostTime`** — capture instant of the batch's first **delivered** frame; the
  independent wall-clock witness.

Invariant: `firstFrameIndex + droppedFrames` tracks total device-produced frames,
which tracks `hostTime` elapsed × rate. A drop is therefore visible two independent,
corroborating ways — `droppedFrames` ticks up, and `hostTime` advances faster than
`firstFrameIndex` alone predicts. Muxer silence-to-insert falls out:
`silence = hostTime_gap − firstFrameIndex_gap / rate`, cross-checked against the
`droppedFrames` delta.

## Ring-span invariant (named constraint)

The **anchor ring must outspan the PCM ring**, with margin (current: anchor ~2.5s
vs PCM ~0.34s / 16384 frames).

> **Why it holds:** dropped frames are gone, not queued behind — so the reader is at
> most one PCM-ring-depth (~0.34s) behind in delivered frames, comfortably inside the
> anchor window. Every drainable frame is therefore always bracketed by two live
> anchors, even mid-stall, which is what makes interpolation well-posed under drops.
> **If anyone resizes either ring, this relationship must be preserved.** State this
> next to the ring definitions.

## Reader shape — one new reader this slice

Ship exactly **`mc_read_frames_timed`** — the stitcher is its real caller. Do **not**
add a redundant second untimed variant "just in case." Record in the doc that a
differently-shaped reader is a **deferred open call**, to be made only when a
genuinely different access pattern has a real caller — written down, not shipped, not
blocking this slice.

---

## Slice-1 measurement — two legs (both required)

Clean loopback alone proves nothing the feature needs — naive sample-counting passes
it too. The gap leg is the point.

**Leg 1 — clean bias/drift.** Impulse once/sec; track `bias = t_report − t_emit`.
Pass: sub-ms spread, no monotonic trend over ≥20 min (ideally the full hour),
`droppedFrames == 0`. Yields the constant-bias number and proves no drift on clean
capture.

**Leg 2 — induced-gap survival (proves the feature exists).** Deliberately stall the
drain past a known window to force a **real** ring overflow, then assert:
1. `droppedFrames` equals the induced gap within tolerance,
2. the first post-gap impulse's `hostTime` still places it correctly on the timeline
   (the anchor survived the gap),
3. `firstFrameIndex` stayed continuous across it.

Assertions 2–3 are exactly what catch the two drop-time anchor bugs: an anchor
indexed on *captured* rather than *written* frames, and duplicate anchors from
zero-commit callbacks. Both pass clean capture and fail only here — which is why this
leg, not Leg 1, is what makes the anchor contract real.

**The stall must be sized deliberately close to the PCM-ring bound** so the test
*fails if the ring-span margin ever erodes*. A comfortable arbitrary gap makes the
invariant decorative; this leg has to defend it.

**Unit coverage — the interpolation math (`test/mc_interp_test.c`).** The pure
`mc_interp` (extracted to `src/mc_anchor.h`) is unit-tested off-device, deterministically
covering both branches — bracketed interpolation *and* extrapolation past the newest
anchor (with the last segment's slope), plus single-anchor flat and ring wrap-around.
Extrapolation is otherwise only hit nondeterministically by live draining, so this is
where a bad slope would otherwise ride out unchecked.

---

## Out of scope / untouched

- No consuming muxer, no stitcher, no README rewrite this slice.
- Leave the stale `pubspec` / `CHANGELOG` iOS cruft alone — separate deliberate call.
- No commit. Working tree, hand back for read.
