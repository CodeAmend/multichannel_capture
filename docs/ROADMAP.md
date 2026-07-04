# Roadmap

Phased plan from "plumbing proven" to "real multichannel capture". Each phase
is a self-contained, verifiable step. Status is updated as phases land.

| Phase | Goal | Status |
|-------|------|--------|
| 0 | Project scaffold, FFI plumbing proven (`sum` demo), repo + tooling | ✅ done |
| 1 | Vendor miniaudio, prove it compiles & links (`mc_version` smoke test) | ✅ done |
| 2 | Enumerate input devices (name, channels, default) | ✅ done |
| 3 | Capture PCM from a selected device into a Dart `Stream` | ✅ done |
| 4 | Example becomes a real demo (pick device → start → level meters / WAV) | 🔶 mostly done |
| 5 | Timed capture: per-buffer host-clock timestamps; timed/untimed as equal peer views over one always-anchoring engine | 🔶 slice 1 spec'd |

## Phase 3 — capture (done)

The hard part of the whole project: getting audio frames from miniaudio's
capture callback (a high-priority native thread) into Dart safely, without
blocking the audio thread or the UI isolate. Shipped as:

- **C**: open a device by index (or null id for the system default — see
  [FINDINGS](FINDINGS.md) on why the `isDefault` flag is unreliable). The
  capture callback writes frames into a lock-free `ma_pcm_rb` ring buffer and
  pings Dart; `mc_read_frames` drains it. Always interleaved f32.
- **Handoff**: `NativeCallable.listener` lets the audio thread wake Dart safely;
  the ring buffer carries the data, fully decoupling realtime from the event loop.
- **Dart**: `startCapture()` → `AudioCapture` with a `Stream<Float32List>`.
- **macOS permissions**: audio-input entitlement + mic usage description.

Verified: `flutter test integration_test -d macos` streams frames end to end.

## Phase 4 — example demo (mostly done)

The example now does: pick device → start → live RMS level meter + frame
counter → **record to a WAV file** and show the saved path. WAV writing lives in
the library as `WavRecorder` (Dart-side, 16-bit PCM, synchronous I/O so the
realtime thread is never touched — see [FINDINGS](FINDINGS.md)).

Still to do: per-channel meters so a multichannel device (e.g. a 6-channel
interface) shows each input separately rather than one averaged bar.

## Phase 5 — timed capture (slice 1 spec'd)

Per-buffer capture timestamps on the mach host clock, so a downstream muxer can
place this audio on the *same* timeline as AVFoundation video (both stamped against
`CMClockGetHostTimeClock`). Full detail + slice-1 measurement in
[PROPOSAL-timestamps.md](PROPOSAL-timestamps.md); the shape:

- **One engine, two equal views.** The capture engine **always** anchors — it samples
  `mach_absolute_time()` at the top of the callback and writes one anchor into a
  companion circular array. `frames` / `mc_read_frames` (untimed) and `timedFrames` /
  `mc_read_frames_timed` (timed) are peer readers over the **same** PCM ring, not a
  base path plus a bolt-on. The untimed path is byte-for-byte what ships today;
  timing is a side-channel it never consults.
- **Path B** (own C only). Sample the clock in our callback; **no `miniaudio.h`
  patch** (would fork a vendored header forever). Bias is a constant, non-accumulating
  callback-dispatch latency.
- **`hostTime` is raw mach host-time units, not nanoseconds** — feeds
  `CMClockMakeHostTimeFromSystemUnits` directly, one representation shared with video
  PTS, zero conversion. Additive-reversible: a `hostTimeNs` accessor can be added
  later if a non-CoreMedia consumer ever appears.
- **Two named invariants** (see spec): `firstFrameIndex` is delivered-only and never
  skips, with drops surfaced separately via `droppedFrames` (corroborating the
  `hostTime` witness); and the **anchor ring must outspan the PCM ring** so every
  drainable frame stays bracketed by live anchors even mid-stall.
- **Two deliberate declines:** never gate anchoring on whether a timed reader is
  attached (consumer-independence), and never reimplement untimed to delegate through
  the timed reader (keeps the load-bearing pump drain off the interpolation path).

Slice 1 lands the native anchor path + `timedFrames` / `droppedFrames` and proves it
with a two-leg measurement (clean bias/drift over ≥20 min, and induced-gap survival
sized to defend the ring-span invariant). No muxer, no README rewrite this slice.
