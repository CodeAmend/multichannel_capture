
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'multichannel_capture_bindings_generated.dart';

/// The version of the bundled miniaudio library, e.g. `"0.11.25"`.
///
/// Smoke test confirming the native miniaudio backend is compiled and linked.
String version() => _bindings.mc_version().cast<Utf8>().toDartString();

/// An audio input (capture) device reported by the operating system.
class CaptureDevice {
  /// Human-readable device name, e.g. `"MacBook Pro Microphone"`.
  final String name;

  /// Stable index into the native device list, used to open the device later.
  ///
  /// Only valid until the next call to [listInputDevices].
  final int index;

  /// Native channel count, or 0 if the backend reports "any" (its wildcard).
  final int channels;

  /// Whether the backend flags this as a default device.
  ///
  /// Treat this as a UI hint only, not a selection mechanism. On macOS this
  /// can be `true` for more than one input device: miniaudio's Core Audio
  /// enumeration leaks the default-*output* flag onto any device that also
  /// supports input (e.g. a loopback). To actually capture from the system
  /// default input, open a null device id rather than picking this entry.
  final bool isDefault;

  const CaptureDevice({
    required this.name,
    required this.index,
    required this.channels,
    required this.isDefault,
  });

  @override
  String toString() =>
      'CaptureDevice(name: $name, index: $index, channels: $channels, '
      'isDefault: $isDefault)';
}

/// Enumerates the available audio input devices.
///
/// Re-query this to pick up hardware that was plugged in or removed; the
/// [CaptureDevice.index] values are only valid until the next call.
///
/// Throws a [StateError] if the native backend fails to enumerate devices.
List<CaptureDevice> listInputDevices() {
  final int count = _bindings.mc_refresh_input_devices();
  if (count < 0) {
    throw StateError('Failed to enumerate input devices');
  }
  return List<CaptureDevice>.generate(count, (int i) {
    final Pointer<Char> namePtr = _bindings.mc_input_device_name(i);
    final String name =
        namePtr == nullptr ? '' : namePtr.cast<Utf8>().toDartString();
    return CaptureDevice(
      name: name,
      index: i,
      channels: _bindings.mc_input_device_channels(i),
      isDefault: _bindings.mc_input_device_is_default(i) != 0,
    );
  });
}

/// A very short-lived native function.
///
/// For very short-lived functions, it is fine to call them on the main isolate.
/// They will block the Dart execution while running the native function, so
/// only do this for native functions which are guaranteed to be short-lived.
int sum(int a, int b) => _bindings.sum(a, b);

/// A longer lived native function, which occupies the thread calling it.
///
/// Do not call these kind of native functions in the main isolate. They will
/// block Dart execution. This will cause dropped frames in Flutter applications.
/// Instead, call these native functions on a separate isolate.
///
/// Modify this to suit your own use case. Example use cases:
///
/// 1. Reuse a single isolate for various different kinds of requests.
/// 2. Use multiple helper isolates for parallel execution.
Future<int> sumAsync(int a, int b) async {
  final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
  final int requestId = _nextSumRequestId++;
  final _SumRequest request = _SumRequest(requestId, a, b);
  final Completer<int> completer = Completer<int>();
  _sumRequests[requestId] = completer;
  helperIsolateSendPort.send(request);
  return completer.future;
}

const String _libName = 'multichannel_capture';

/// The dynamic library in which the symbols for [MultichannelCaptureBindings] can be found.
final DynamicLibrary _dylib = () {
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.open('$_libName.framework/$_libName');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('lib$_libName.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('$_libName.dll');
  }
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}();

/// The bindings to the native functions in [_dylib].
final MultichannelCaptureBindings _bindings = MultichannelCaptureBindings(_dylib);

/// A request to compute `sum`.
///
/// Typically sent from one isolate to another.
class _SumRequest {
  final int id;
  final int a;
  final int b;

  const _SumRequest(this.id, this.a, this.b);
}

/// A response with the result of `sum`.
///
/// Typically sent from one isolate to another.
class _SumResponse {
  final int id;
  final int result;

  const _SumResponse(this.id, this.result);
}

/// Counter to identify [_SumRequest]s and [_SumResponse]s.
int _nextSumRequestId = 0;

/// Mapping from [_SumRequest] `id`s to the completers corresponding to the correct future of the pending request.
final Map<int, Completer<int>> _sumRequests = <int, Completer<int>>{};

/// The SendPort belonging to the helper isolate.
Future<SendPort> _helperIsolateSendPort = () async {
  // The helper isolate is going to send us back a SendPort, which we want to
  // wait for.
  final Completer<SendPort> completer = Completer<SendPort>();

  // Receive port on the main isolate to receive messages from the helper.
  // We receive two types of messages:
  // 1. A port to send messages on.
  // 2. Responses to requests we sent.
  final ReceivePort receivePort = ReceivePort()
    ..listen((dynamic data) {
      if (data is SendPort) {
        // The helper isolate sent us the port on which we can sent it requests.
        completer.complete(data);
        return;
      }
      if (data is _SumResponse) {
        // The helper isolate sent us a response to a request we sent.
        final Completer<int> completer = _sumRequests[data.id]!;
        _sumRequests.remove(data.id);
        completer.complete(data.result);
        return;
      }
      throw UnsupportedError('Unsupported message type: ${data.runtimeType}');
    });

  // Start the helper isolate.
  await Isolate.spawn((SendPort sendPort) async {
    final ReceivePort helperReceivePort = ReceivePort()
      ..listen((dynamic data) {
        // On the helper isolate listen to requests and respond to them.
        if (data is _SumRequest) {
          final int result = _bindings.sum_long_running(data.a, data.b);
          final _SumResponse response = _SumResponse(data.id, result);
          sendPort.send(response);
          return;
        }
        throw UnsupportedError('Unsupported message type: ${data.runtimeType}');
      });

    // Send the port to the main isolate on which we can receive requests.
    sendPort.send(helperReceivePort.sendPort);
  }, receivePort.sendPort);

  // Wait until the helper isolate has sent us back the SendPort on which we
  // can start sending requests.
  return completer.future;
}();
