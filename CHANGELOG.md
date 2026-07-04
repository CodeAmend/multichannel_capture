## 0.2.0

* **Timed capture (macOS).** Per-buffer host-clock timestamps for placing capture
  audio on the same timeline as AVFoundation video when muxing. New
  `AudioCapture.timedFrames` — a `Stream<TimedAudioBatch>` carrying the PCM plus
  the first frame's `hostTime` (**raw mach host units**, as fed to
  `CMClockMakeHostTimeFromSystemUnits`) and a delivered-only, continuous
  `firstFrameIndex` — and `AudioCapture.droppedFrames`. Backed by new native
  `mc_read_frames_timed` / `mc_capture_dropped_frames`.
* The capture engine now always anchors (one host-time anchor per committing
  callback); the untimed `frames` path is unchanged, and `frames` / `timedFrames`
  are mutually exclusive per session (claiming both throws synchronously).

> **Why the jump from 0.0.1 to 0.2.0 (no 0.1.0)?** The initial release was really a
> 0.1.0-grade milestone — real device-selected stereo PCM capture, the whole reason
> the package exists — just under-labeled as 0.0.1. Timed capture is the second
> substantial capability, so it lands at 0.2.0 and 0.1.0 is skipped on purpose.

## 0.0.1

* TODO: Describe initial release.
