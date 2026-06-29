# Roadmap

Phased plan from "plumbing proven" to "real multichannel capture". Each phase
is a self-contained, verifiable step. Status is updated as phases land.

| Phase | Goal | Status |
|-------|------|--------|
| 0 | Project scaffold, FFI plumbing proven (`sum` demo), repo + tooling | ✅ done |
| 1 | Vendor miniaudio, prove it compiles & links (`mc_version` smoke test) | ✅ done |
| 2 | Enumerate input devices (name, channels, default) | ✅ done |
| 3 | Capture PCM from a selected device into a Dart `Stream` | ✅ done |
| 4 | Example becomes a real demo (pick device → start → level meters / WAV) | 🔶 partial |

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

## Phase 4 — example demo (partial)

The example already does: pick device → start → live RMS level meter + frame
counter. Still to do: write captured audio to a WAV file (miniaudio's
`ma_encoder` can do this), and per-channel meters for multichannel devices.
