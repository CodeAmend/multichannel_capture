// Integration tests for the multichannel_capture plugin.
//
// These run on a real platform target (e.g. macOS) with the native library
// loaded, which is the only place FFI calls can be exercised. Run with:
//
//   flutter test integration_test -d macos
//
// Plain `flutter test` cannot run these — the native .framework is not loaded
// in the headless host VM.

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

  test('sum returns the sum of its arguments', () {
    expect(multichannel_capture.sum(1, 2), 3);
  });

  test('sumAsync returns the sum from a helper isolate', () async {
    expect(await multichannel_capture.sumAsync(3, 4), 7);
  });
}
