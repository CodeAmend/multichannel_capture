// Integration tests for the multichannel_capture plugin.
//
// These run on a real platform target (e.g. macOS) with the native library
// loaded, which is the only place FFI calls can be exercised. Run with:
//
//   flutter test integration_test -d macos
//
// Plain `flutter test` cannot run these — the native .framework is not loaded
// in the headless host VM.

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

  test('sum returns the sum of its arguments', () {
    expect(multichannel_capture.sum(1, 2), 3);
  });

  test('sumAsync returns the sum from a helper isolate', () async {
    expect(await multichannel_capture.sumAsync(3, 4), 7);
  });
}
