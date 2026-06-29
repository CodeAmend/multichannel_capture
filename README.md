# multichannel_capture

**Real-time multichannel (stereo and beyond) audio _input_ capture from a _selectable device_, as a PCM stream — for Flutter, cross-platform.**

> 🚧 **Early development.** macOS first; not yet on pub.dev. Built because every existing option failed (see below). APIs shown here are the target shape and will firm up as platforms land.

---

## What problem does this solve?

**Flutter has no way to capture stereo/multichannel audio from a _chosen input device_ as a live PCM stream.** That's the whole reason this exists.

Every existing Flutter audio package wraps the **high-level OS capture APIs** (AVAudioEngine / AVCaptureSession on Apple, the equivalents elsewhere). Those APIs treat audio input as a **mono microphone** — they downmix everything to one channel, and most don't let you choose _which_ device. That's perfect for a voice memo. It is **useless** for:

- 🎹 **music apps** — an instrument or audio interface is inherently **stereo**; collapsing it to mono throws away the performance,
- 🎙️ **podcasting / multi-mic** setups,
- 📡 **streaming / broadcast**,
- 📞 **conferencing** — feeding a WebRTC SDK (Agora, LiveKit, etc.) a real stereo source via its external-audio input.

The capability is right there in the OS — every DAW, Zoom, and OBS captures multichannel via CoreAudio / WASAPI. It was simply **never exposed to Flutter.** This package is that missing layer.

> **Why it's built this way:** I needed to capture a stereo instrument feed from an audio interface in a Flutter music-teaching app. I tried every package on pub.dev — one captured mono, one wouldn't compile, one recorded pure silence. The OS can do it; the Flutter ecosystem just had a hole. So this fills the hole.

## What it does

- **Enumerate input devices** — names + ids, so your app can show a real **device picker**.
- **Capture a chosen device** at your requested **channel count** (2+), sample rate, and bit depth.
- Delivers raw **PCM as a `Stream<Uint8List>`** — record it, analyze it, or pipe it into another SDK.
- **Cross-platform via [miniaudio](https://miniaud.io/)** — one public-domain C library that already speaks CoreAudio (macOS/iOS), WASAPI (Windows), AAudio (Android), and ALSA/PulseAudio (Linux). Bound to Dart over FFI.

## Quick example _(target API — not all platforms live yet)_

```dart
final cap = MultichannelCapture();

// List inputs and let the user pick one (real device selection).
final devices = await cap.listInputDevices();
final rig = devices.firstWhere((d) => d.name.contains('Scarlett'));

// Capture it in STEREO as a live PCM stream.
final stream = await cap.startCapture(
  device: rig,
  channels: 2,
  sampleRate: 48000,
);

stream.listen((Uint8List pcm) {
  // Raw interleaved 16-bit PCM frames — write to a WAV,
  // run DSP, or push to a WebRTC external audio source.
});

await cap.stop();
```

## Platform support

| Platform | Status |
| --- | --- |
| macOS | 🚧 in progress |
| iOS / iPadOS | planned |
| Windows | 🙏 help wanted (miniaudio = WASAPI; mostly build + test) |
| Linux | 🙏 help wanted |
| Android | planned |
| Web | ❌ not supported — FFI/C can't run in the browser; use the WebAudio API there |

## How it works

A thin **Dart FFI binding to miniaudio**. miniaudio opens the selected device at the requested channel layout and hands us frames via a capture callback; we stream those PCM frames to Dart on a background isolate so the UI never blocks. No per-platform native code to maintain — miniaudio's single C file handles every OS.

## Contributing

PRs and issues welcome — especially **Windows and Linux** support. The capture logic is cross-platform C; those platforms are mostly **build wiring + testing on real hardware**. Look for issues tagged `help wanted`.

---

## For contributors: project layout

| Path | What it is |
| --- | --- |
| `src/` | The C source + `CMakeLists.txt`. miniaudio + a thin wrapper compiled into a native library. |
| `lib/multichannel_capture.dart` | The public Dart API (what you import). |
| `lib/multichannel_capture_bindings_generated.dart` | Auto-generated Dart↔C glue — **do not hand-edit.** |
| `ffigen.yaml` | Config for `ffigen`, which generates the bindings from `src/*.h`. |
| `macos/`, `ios/`, … | Per-platform build files that compile + bundle the native library. |
| `example/` | A runnable demo app used to develop and test the plugin. |

**Regenerate the C bindings** after changing `src/multichannel_capture.h`:

```bash
dart run ffigen --config ffigen.yaml
```

**Run the example app** (the dev/test harness):

```bash
cd example && flutter run -d macos
```

Built on Flutter's `--template=plugin_ffi`. See Flutter's [FFI plugin docs](https://flutter.dev/to/ffi-package).

## License

[MIT](LICENSE) — do whatever you want with it.