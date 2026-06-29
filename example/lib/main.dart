import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:multichannel_capture/multichannel_capture.dart'
    as multichannel_capture;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // ScaffoldMessenger lives inside MaterialApp, below this State's context, so
  // ScaffoldMessenger.of(context) can't find it. A key reaches it from anywhere.
  final GlobalKey<ScaffoldMessengerState> _messengerKey = GlobalKey();

  late List<multichannel_capture.CaptureDevice> _devices;

  multichannel_capture.AudioCapture? _capture;
  StreamSubscription<Float32List>? _subscription;
  int? _capturingIndex;
  double _level = 0; // RMS of the most recent frames, 0..1.
  int _framesReceived = 0;

  multichannel_capture.WavRecorder? _recorder;
  String? _lastSavedPath;

  @override
  void initState() {
    super.initState();
    _devices = multichannel_capture.listInputDevices();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _devices = multichannel_capture.listInputDevices();
    });
  }

  void _stop() {
    _recorder?.stop();
    if (_recorder != null) _lastSavedPath = _recorder!.path;
    _recorder = null;
    _subscription?.cancel();
    _subscription = null;
    _capture?.stop();
    _capture = null;
    _capturingIndex = null;
    _level = 0;
    _framesReceived = 0;
  }

  void _snack(String message) {
    if (!mounted) return;
    _messengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openSaved({bool reveal = false}) async {
    final path = _lastSavedPath;
    if (path == null) return;
    // Absolute path: a GUI app's PATH may not include /usr/bin. `open`
    // launches the default player (QuickTime); `open -R` reveals in Finder.
    final args = reveal ? ['-R', path] : [path];
    try {
      final result = await Process.run('/usr/bin/open', args);
      debugPrint('open exit=${result.exitCode} '
          'stdout=${result.stdout} stderr=${result.stderr}');
      if (result.exitCode == 0) return;
      // Non-zero usually means the sandbox blocked it or no handler exists.
      Clipboard.setData(ClipboardData(text: path));
      _snack('open failed (exit ${result.exitCode}): '
          '${(result.stderr as String).trim()} — path copied.');
    } catch (e, st) {
      debugPrint('open threw: $e\n$st');
      Clipboard.setData(ClipboardData(text: path));
      _snack('Could not launch open ($e). Path copied — '
          'run `afplay <path>` in a terminal.');
    }
  }

  void _copySaved() {
    final path = _lastSavedPath;
    if (path == null) return;
    Clipboard.setData(ClipboardData(text: path));
    _snack('Path copied to clipboard');
  }

  void _toggleRecord() {
    final capture = _capture;
    if (capture == null) return;
    setState(() {
      if (_recorder != null) {
        _recorder!.stop();
        _lastSavedPath = _recorder!.path;
        _recorder = null;
      } else {
        final path = '${Directory.systemTemp.path}/multichannel_capture_'
            '${DateTime.now().millisecondsSinceEpoch}.wav';
        _recorder = multichannel_capture.WavRecorder.start(
          path,
          channels: capture.channels,
          sampleRate: capture.sampleRate,
        );
        _lastSavedPath = null;
      }
    });
  }

  void _toggleCapture(int index) {
    // Tapping the active device stops it.
    if (_capturingIndex == index) {
      setState(_stop);
      return;
    }

    setState(_stop);
    try {
      final capture = multichannel_capture.startCapture(deviceIndex: index);
      _subscription = capture.frames.listen((frame) {
        _recorder?.addFrame(frame);
        var sumSquares = 0.0;
        for (final sample in frame) {
          sumSquares += sample * sample;
        }
        final rms = frame.isEmpty ? 0.0 : math.sqrt(sumSquares / frame.length);
        setState(() {
          _level = rms.clamp(0.0, 1.0);
          _framesReceived += frame.length ~/ capture.channels;
        });
      });
      setState(() {
        _capture = capture;
        _capturingIndex = index;
      });
    } catch (e) {
      _messengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    const titleStyle = TextStyle(fontSize: 20, fontWeight: FontWeight.bold);
    final capture = _capture;
    return MaterialApp(
      scaffoldMessengerKey: _messengerKey,
      home: Scaffold(
        appBar: AppBar(
          title: const Text('multichannel_capture'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Re-scan devices',
              onPressed: _capture == null ? _refresh : null,
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'miniaudio ${multichannel_capture.version()} · '
                '${_devices.length} input device'
                '${_devices.length == 1 ? '' : 's'}',
                style: titleStyle,
              ),
            ),
            if (capture != null) _captureBanner(capture),
            if (_recorder == null && _lastSavedPath != null)
              _lastRecordingBar(),
            const Divider(height: 1),
            Expanded(
              child: _devices.isEmpty
                  ? const Center(child: Text('No input devices found'))
                  : ListView.builder(
                      itemCount: _devices.length,
                      itemBuilder: (context, i) {
                        final d = _devices[i];
                        final capturing = _capturingIndex == i;
                        return ListTile(
                          leading: Icon(
                            capturing
                                ? Icons.stop_circle
                                : (d.isDefault ? Icons.star : Icons.mic),
                            color: capturing ? Colors.red : null,
                          ),
                          title: Text(d.name),
                          subtitle: Text(
                            'index ${d.index} · '
                            '${d.channels == 0 ? 'any' : '${d.channels}'} ch'
                            '${d.isDefault ? ' · default' : ''}',
                          ),
                          trailing: Text(capturing ? 'tap to stop' : 'tap to capture'),
                          onTap: () => _toggleCapture(i),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _captureBanner(multichannel_capture.AudioCapture capture) {
    return Container(
      width: double.infinity,
      color: Colors.red.withValues(alpha: 0.08),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Capturing · ${capture.channels} ch @ ${capture.sampleRate} Hz · '
            '$_framesReceived frames',
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _level,
              minHeight: 10,
              backgroundColor: Colors.black12,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _toggleRecord,
                icon: Icon(_recorder != null
                    ? Icons.stop
                    : Icons.fiber_manual_record),
                label: Text(_recorder != null ? 'Stop recording' : 'Record WAV'),
              ),
              const SizedBox(width: 12),
              if (_recorder != null) const Text('● recording…'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _lastRecordingBar() {
    return Container(
      width: double.infinity,
      color: Colors.green.withValues(alpha: 0.08),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          const Icon(Icons.audiotrack, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _lastSavedPath ?? '',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Show in Finder',
            onPressed: () => _openSaved(reveal: true),
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy path',
            onPressed: _copySaved,
          ),
        ],
      ),
    );
  }
}
