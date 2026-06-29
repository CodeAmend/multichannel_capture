# API reference

The public Dart API of `package:multichannel_capture`. Import it:

```dart
import 'package:multichannel_capture/multichannel_capture.dart'
    as multichannel_capture;
```

All audio is **interleaved 32-bit float** (`Float32List`) unless otherwise noted.

---

## `String version()`

Returns the bundled miniaudio version string, e.g. `"0.11.25"`. Useful as a
smoke test that the native backend is linked.

---

## Device enumeration

### `class CaptureDevice`

| Member | Type | Description |
|--------|------|-------------|
| `name` | `String` | Human-readable device name, e.g. `"Scarlett 4i4 4th Gen"`. |
| `index` | `int` | Index used to select the device in `startCapture`. Valid only until the next `listInputDevices()` call. |
| `channels` | `int` | Native channel count. `0` means the backend reports "any". |
| `isDefault` | `bool` | Backend default flag. **UI hint only** — may be `true` for more than one device on macOS; do not use it to select the default mic (pass no `deviceIndex` instead). |

### `List<CaptureDevice> listInputDevices()`

Enumerates the available input devices (synchronous). Re-query to pick up
hardware changes; indices are only valid until the next call. Throws
`StateError` if the backend fails to enumerate.

```dart
final devices = multichannel_capture.listInputDevices();
for (final d in devices) {
  print('${d.index}: ${d.name} (${d.channels} ch)');
}
```

---

## Capture

### `AudioCapture startCapture({int? deviceIndex, int sampleRate = 0, int channels = 0})`

Starts capturing from `deviceIndex` (from `listInputDevices`), or the system
default input if omitted/`null`. Pass `sampleRate`/`channels` to request
specific values, or leave `0` to accept the device's native configuration.
Throws `StateError` if the device can't open (permission denied, or a capture is
already running — only one session at a time).

### `class AudioCapture`

| Member | Type | Description |
|--------|------|-------------|
| `channels` | `int` | Negotiated channel count (samples per frame in `frames`). |
| `sampleRate` | `int` | Negotiated sample rate in Hz. |
| `frames` | `Stream<Float32List>` | Interleaved f32 PCM, each event a freshly copied buffer of `frameCount * channels` samples. |
| `stop()` | `void` | Stops capture, releases the device, closes `frames`. Also runs automatically if the `frames` subscription is cancelled. |

```dart
final cap = multichannel_capture.startCapture(deviceIndex: 0);
final sub = cap.frames.listen((Float32List frame) {
  // frame.length == frameCount * cap.channels, interleaved.
});
// later:
cap.stop(); // or sub.cancel();
```

---

## Recording

### `class WavRecorder`

Writes captured f32 frames to a 16-bit PCM WAV file (converted from f32, so
lossy at the bit-depth level). Synchronous I/O — for very long/high-channel
recordings, drive it from a dedicated isolate.

| Member | Type | Description |
|--------|------|-------------|
| `WavRecorder.start(path, {required channels, required sampleRate})` | factory | Opens `path` and writes a placeholder header. |
| `path` | `String` | The file being written. |
| `channels`, `sampleRate` | `int` | Audio format being written. |
| `addFrame(Float32List frame)` | `void` | Appends one interleaved f32 frame (converted to s16). |
| `stop()` | `void` | Finalizes the WAV header and closes the file. |

```dart
final rec = multichannel_capture.WavRecorder.start(
  '/tmp/out.wav',
  channels: cap.channels,
  sampleRate: cap.sampleRate,
);
cap.frames.listen(rec.addFrame);
// later: rec.stop();
```

---

## Legacy demo functions (to be removed)

`int sum(int, int)` and `Future<int> sumAsync(int, int)` remain from the FFI
plugin template's scaffold and will be removed once the capture API stabilizes.

---

## Native (C) surface — for contributors

The Dart API is a thin binding over these exported C functions (see
`src/multichannel_capture.h`), regenerated into Dart via ffigen:

| Function | Purpose |
|----------|---------|
| `const char *mc_version(void)` | miniaudio version string |
| `int mc_refresh_input_devices(void)` | (re)enumerate; returns count or -1 |
| `int mc_input_device_count(void)` | cached device count |
| `const char *mc_input_device_name(int)` | device name by index |
| `int mc_input_device_is_default(int)` | default flag by index |
| `int mc_input_device_channels(int)` | native channel count by index |
| `int mc_start_capture(int, int, int, cb)` | open + start capture |
| `int mc_read_frames(float *, int)` | drain ring buffer; returns frames read |
| `int mc_stop_capture(void)` | stop + release |
| `int mc_capture_channels(void)` | running capture channel count |
| `int mc_capture_sample_rate(void)` | running capture sample rate |
