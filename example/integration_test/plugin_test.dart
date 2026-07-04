// Integration tests for the multichannel_capture plugin.
//
// These run on a real platform target (e.g. macOS) with the native library
// loaded, which is the only place FFI calls can be exercised. Run with:
//
//   flutter test integration_test -d macos
//
// Plain `flutter test` cannot run these — the native .framework is not loaded
// in the headless host VM.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:multichannel_capture/multichannel_capture.dart'
    as multichannel_capture;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Smoke test: proves the native library loads, the mc_version symbol
  // resolves, and the Core Audio backend links at runtime — the automated
  // equivalent of launching the example and reading the version on screen.
  test('miniaudio version is reported from native code', () {
    final version = multichannel_capture.version();
    expect(version, isNotEmpty);
    // Pinned to the vendored single-header version in src/miniaudio.h.
    expect(version, '0.11.25');
  });

  group('input device enumeration', () {
    test('returns at least one device on a machine with a microphone', () {
      final devices = multichannel_capture.listInputDevices();
      // CI/dev machines running these tests have at least a built-in mic.
      expect(devices, isNotEmpty);
    });

    test('devices have names and sequential indices', () {
      final devices = multichannel_capture.listInputDevices();
      for (var i = 0; i < devices.length; i++) {
        expect(devices[i].index, i);
        expect(devices[i].name, isNotEmpty);
        expect(devices[i].channels, greaterThanOrEqualTo(0));
      }
    });

    // NOTE: We deliberately do NOT assert "exactly one default". miniaudio's
    // Core Audio enumeration can flag more than one input device as default:
    // a device that is the default *output* and also supports input (e.g. a
    // loopback) leaks the default flag into the capture list. isDefault is a
    // UI hint only; selecting the real default mic means opening a null
    // device id, not picking the isDefault entry. See CaptureDevice.isDefault.
  });

  group('capture', () {
    test('opens the default device and streams PCM frames', () async {
      final capture = multichannel_capture.startCapture();
      addTearDown(capture.stop);

      // Device negotiated a real configuration.
      expect(capture.channels, greaterThan(0));
      expect(capture.sampleRate, greaterThan(0));

      // Frames flow from the native audio thread into the Dart stream. (The
      // values may be silence if mic permission is denied, but the pipeline
      // still delivers buffers — this proves the ring buffer + NativeCallable
      // handoff works end to end.)
      final frame = await capture.frames.first.timeout(
        const Duration(seconds: 5),
      );
      expect(frame, isA<Float32List>());
      expect(frame.length % capture.channels, 0);
      expect(frame, isNotEmpty);
    });

    test('rejects a second concurrent capture', () {
      final capture = multichannel_capture.startCapture();
      addTearDown(capture.stop);
      expect(multichannel_capture.startCapture, throwsStateError);
    });

    test('records captured audio to a valid WAV file', () async {
      final capture = multichannel_capture.startCapture();
      final path =
          '${Directory.systemTemp.path}/mc_test_${capture.sampleRate}.wav';
      final recorder = multichannel_capture.WavRecorder.start(
        path,
        channels: capture.channels,
        sampleRate: capture.sampleRate,
      );

      // Record a handful of real frames.
      var frames = 0;
      await for (final frame in capture.frames) {
        recorder.addFrame(frame);
        if (++frames >= 10) break;
      }
      recorder.stop();
      capture.stop();

      final file = File(path);
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });

      final bytes = file.readAsBytesSync();
      expect(bytes.length, greaterThan(44)); // header + at least some audio
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');

      // The data-chunk size in the header must match the bytes written.
      final view = ByteData.view(bytes.buffer);
      final dataSize = view.getUint32(40, Endian.little);
      expect(dataSize, bytes.length - 44);
      // 16-bit samples * channels must divide the data evenly.
      expect(dataSize % (capture.channels * 2), 0);
    });
  });

  // Timed capture (Phase 5). These are the automatable structural checks — the
  // full sign-off measurement (loopback impulse bias + ≥20-min drift regression,
  // and the long induced-gap survival run) is run MANUALLY with a loopback rig,
  // per docs/PROPOSAL-timestamps.md. These prove plumbing, index continuity, and
  // that a drop is counted without punching a hole in the delivered index.
  group('timed capture', () {
    // Collect [n] timed batches (or until [timeout]).
    Future<List<multichannel_capture.TimedAudioBatch>> collectTimed(
      multichannel_capture.AudioCapture capture,
      int n, {
      Duration timeout = const Duration(seconds: 8),
    }) {
      final out = <multichannel_capture.TimedAudioBatch>[];
      final done = Completer<List<multichannel_capture.TimedAudioBatch>>();
      late final StreamSubscription sub;
      sub = capture.timedFrames.listen((b) {
        out.add(b);
        if (out.length >= n && !done.isCompleted) {
          done.complete(out);
          sub.cancel();
        }
      }, onError: (e) {
        if (!done.isCompleted) done.completeError(e);
      });
      return done.future.timeout(timeout, onTimeout: () {
        sub.cancel();
        return out;
      });
    }

    test('delivers host-stamped batches with continuous delivered indices',
        () async {
      final capture = multichannel_capture.startCapture();
      addTearDown(capture.stop);

      final batches = await collectTimed(capture, 15);
      expect(batches.length, greaterThan(1),
          reason: 'timed stream should deliver batches from a live input');

      for (final b in batches) {
        expect(b.samples, isNotEmpty);
        expect(b.samples.length % capture.channels, 0);
      }

      // hostTime strictly increasing; firstFrameIndex exactly continuous with the
      // cumulative delivered sample count (no gap, no skip) on a promptly-drained
      // — therefore drop-free — session.
      for (var i = 1; i < batches.length; i++) {
        final prev = batches[i - 1];
        final cur = batches[i];
        expect(cur.hostTime, greaterThan(prev.hostTime),
            reason: 'hostTime must be strictly increasing');
        final prevFrames = prev.samples.length ~/ capture.channels;
        expect(cur.firstFrameIndex, prev.firstFrameIndex + prevFrames,
            reason: 'delivered index must be continuous');
      }
      expect(capture.droppedFrames, 0,
          reason: 'a promptly-drained session should not drop');
    });

    test('induced drop is counted and leaves the delivered index continuous',
        () async {
      final capture = multichannel_capture.startCapture();
      addTearDown(capture.stop);
      expect(capture.channels, greaterThan(0));

      // Stall: do NOT listen for well over the PCM-ring span (~0.34s), so the
      // native ring overflows and frames are dropped before any drain.
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      // Now drain. The dropped frames were never committed, so the delivered index
      // stays continuous across the gap — the drop shows up as a time jump and in
      // the counter, not as a hole in firstFrameIndex.
      final batches = await collectTimed(capture, 15);
      expect(batches.length, greaterThan(1));

      expect(capture.droppedFrames, greaterThan(0),
          reason: 'a 1.5s stall past the ring span must drop frames');

      for (var i = 1; i < batches.length; i++) {
        final prev = batches[i - 1];
        final cur = batches[i];
        expect(cur.hostTime, greaterThan(prev.hostTime));
        final prevFrames = prev.samples.length ~/ capture.channels;
        expect(cur.firstFrameIndex, prev.firstFrameIndex + prevFrames,
            reason: 'delivered index stays continuous even after a drop');
      }
    });

    test('frames and timedFrames are mutually exclusive (loud, synchronous)', () {
      final capture = multichannel_capture.startCapture();
      addTearDown(capture.stop);

      // Untimed view claims the session...
      final framesSub = capture.frames.listen((_) {});
      addTearDown(framesSub.cancel);

      // ...so accessing the timed view now throws synchronously at the call site,
      // not as a swallowed async stream error.
      expect(() => capture.timedFrames, throwsStateError);
    });
  });

  test('sum returns the sum of its arguments', () {
    expect(multichannel_capture.sum(1, 2), 3);
  });

  test('sumAsync returns the sum from a helper isolate', () async {
    expect(await multichannel_capture.sumAsync(3, 4), 7);
  });
}
