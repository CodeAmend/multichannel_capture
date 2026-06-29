
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

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

/// Number of frames drained from the native ring buffer per notification.
/// At 48kHz this is ~85ms of slack, comfortably larger than a typical audio
/// callback, so a single read keeps up with the device.
const int _maxFramesPerRead = 4096;

/// A live capture session producing interleaved 32-bit float PCM.
///
/// Obtain one from [startCapture]. Listen to [frames] for audio, then call
/// [stop] (or cancel the subscription) to release the device.
class AudioCapture {
  /// Actual channel count negotiated with the device (frames in [frames] are
  /// interleaved with this many samples per frame).
  final int channels;

  /// Actual sample rate negotiated with the device, in Hz.
  final int sampleRate;

  /// Stream of interleaved f32 PCM frames as they are captured.
  ///
  /// Each event is a freshly copied buffer of `frameCount * channels` samples.
  Stream<Float32List> get frames => _controller.stream;

  final StreamController<Float32List> _controller;
  final NativeCallable<Void Function()> _onDataReady;
  final Pointer<Float> _readBuffer;
  bool _stopped = false;

  AudioCapture._(
    this.channels,
    this.sampleRate,
    this._controller,
    this._onDataReady,
    this._readBuffer,
  );

  /// Drain the native ring buffer into the stream. Invoked (via the native
  /// listener) on the Dart event loop whenever frames are available.
  void _drain() {
    if (_stopped) return;
    while (true) {
      final int framesRead =
          _bindings.mc_read_frames(_readBuffer, _maxFramesPerRead);
      if (framesRead <= 0) break;
      final int sampleCount = framesRead * channels;
      // Copy out of the native buffer — it is reused on the next read.
      _controller.add(Float32List.fromList(
        _readBuffer.asTypedList(sampleCount),
      ));
      if (framesRead < _maxFramesPerRead) break;
    }
  }

  /// Stop capturing, release the device, and close [frames].
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _bindings.mc_stop_capture();
    _onDataReady.close();
    calloc.free(_readBuffer);
    _controller.close();
  }
}

/// Starts capturing audio from an input device.
///
/// Pass a [deviceIndex] from [listInputDevices] to pick a device, or omit it
/// (or pass `null`) to use the system default input. Pass [sampleRate] and/or
/// [channels] to request specific values, or leave them `0` to accept the
/// device's native configuration (read the negotiated values back from the
/// returned [AudioCapture]).
///
/// Throws a [StateError] if the device cannot be opened (e.g. microphone
/// permission denied, or a capture is already running).
AudioCapture startCapture({
  int? deviceIndex,
  int sampleRate = 0,
  int channels = 0,
}) {
  final controller = StreamController<Float32List>();
  // Late so the listener can reference the AudioCapture for draining.
  late final AudioCapture capture;
  final onDataReady = NativeCallable<Void Function()>.listener(() {
    capture._drain();
  });

  final int result = _bindings.mc_start_capture(
    deviceIndex ?? -1,
    sampleRate,
    channels,
    onDataReady.nativeFunction,
  );
  if (result != 0) {
    onDataReady.close();
    controller.close();
    throw StateError('Failed to start capture (device unavailable or '
        'microphone permission denied)');
  }

  final int actualChannels = _bindings.mc_capture_channels();
  final int actualSampleRate = _bindings.mc_capture_sample_rate();
  final readBuffer = calloc<Float>(_maxFramesPerRead * actualChannels);

  capture = AudioCapture._(
    actualChannels,
    actualSampleRate,
    controller,
    onDataReady,
    readBuffer,
  );

  // Stop automatically if the consumer cancels their subscription.
  controller.onCancel = capture.stop;
  return capture;
}

/// Writes captured PCM frames to a 16-bit WAV file.
///
/// Feed it the interleaved f32 frames from [AudioCapture.frames] via [addFrame]
/// (samples are clamped and converted to signed 16-bit), then call [stop] to
/// finalize the header. 16-bit PCM is chosen for broad player compatibility;
/// f32 input is converted, so this is lossy at the bit-depth level.
///
/// I/O is synchronous to guarantee frames are written in arrival order. That is
/// fine for a typical recording on the main isolate; for very long or
/// high-channel-count sessions, drive it from a dedicated isolate.
class WavRecorder {
  /// Filesystem path being written to.
  final String path;

  /// Channel count of the audio being written.
  final int channels;

  /// Sample rate of the audio being written, in Hz.
  final int sampleRate;

  final RandomAccessFile _file;
  int _dataBytes = 0;
  bool _closed = false;

  WavRecorder._(this.path, this.channels, this.sampleRate, this._file);

  /// Opens [path] and writes a placeholder WAV header, ready for [addFrame].
  factory WavRecorder.start(
    String path, {
    required int channels,
    required int sampleRate,
  }) {
    final file = File(path).openSync(mode: FileMode.write);
    final recorder = WavRecorder._(path, channels, sampleRate, file);
    // Placeholder header; sizes are patched in [stop].
    file.writeFromSync(recorder._header(0));
    return recorder;
  }

  /// Appends one interleaved f32 [frame], converting samples to s16.
  void addFrame(Float32List frame) {
    if (_closed) {
      throw StateError('WavRecorder is already stopped');
    }
    final bytes = Uint8List(frame.length * 2);
    final view = ByteData.view(bytes.buffer);
    for (var i = 0; i < frame.length; i++) {
      final clamped = frame[i].clamp(-1.0, 1.0);
      view.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
    }
    _file.writeFromSync(bytes);
    _dataBytes += bytes.length;
  }

  /// Finalizes the WAV header with the true sizes and closes the file.
  void stop() {
    if (_closed) return;
    _closed = true;
    _file.setPositionSync(0);
    _file.writeFromSync(_header(_dataBytes));
    _file.closeSync();
  }

  /// Builds a 44-byte canonical WAV header for [dataBytes] of 16-bit PCM.
  Uint8List _header(int dataBytes) {
    const bitsPerSample = 16;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final bytes = Uint8List(44);
    final view = ByteData.view(bytes.buffer);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        bytes[offset + i] = s.codeUnitAt(i);
      }
    }

    ascii(0, 'RIFF');
    view.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    view.setUint32(16, 16, Endian.little); // fmt chunk size
    view.setUint16(20, 1, Endian.little); // audio format: PCM
    view.setUint16(22, channels, Endian.little);
    view.setUint32(24, sampleRate, Endian.little);
    view.setUint32(28, byteRate, Endian.little);
    view.setUint16(32, blockAlign, Endian.little);
    view.setUint16(34, bitsPerSample, Endian.little);
    ascii(36, 'data');
    view.setUint32(40, dataBytes, Endian.little);
    return bytes;
  }
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
