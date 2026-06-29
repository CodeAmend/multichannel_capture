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

  test('sum returns the sum of its arguments', () {
    expect(multichannel_capture.sum(1, 2), 3);
  });

  test('sumAsync returns the sum from a helper isolate', () async {
    expect(await multichannel_capture.sumAsync(3, 4), 7);
  });
}
