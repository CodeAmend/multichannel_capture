# Roadmap

Phased plan from "plumbing proven" to "real multichannel capture". Each phase
is a self-contained, verifiable step. Status is updated as phases land.

| Phase | Goal | Status |
|-------|------|--------|
| 0 | Project scaffold, FFI plumbing proven (`sum` demo), repo + tooling | ✅ done |
| 1 | Vendor miniaudio, prove it compiles & links (`mc_version` smoke test) | ✅ done |
| 2 | Enumerate input devices (name, channels, default) | ✅ done |
| 3 | Capture PCM from a selected device into a Dart `Stream` | ⏳ next |
| 4 | Example becomes a real demo (pick device → start → level meters / WAV) | ⬜ planned |

## Phase 3 — capture (next)

The hard part of the whole project: getting audio frames from miniaudio's
capture callback (a high-priority native thread) into Dart safely, without
blocking the audio thread or the UI isolate.

- C: open a device by index (or null id for the system default — see
  [PLATFORM_NOTES](PLATFORM_NOTES.md) on why the `isDefault` flag is unreliable),
  start a capture callback, push PCM frames out.
- The Dart↔native handoff: native ports / a lock-free ring buffer so the audio
  callback never blocks.
- Dart API: expose it as a `Stream<Uint8List>` of PCM frames.

## Phase 4 — example demo

Pick device → start → show level meters and/or write a WAV file. Turns the
plugin from "it enumerates" into "it captures", end to end.
