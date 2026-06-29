import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

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
  late List<multichannel_capture.CaptureDevice> _devices;

  multichannel_capture.AudioCapture? _capture;
  StreamSubscription<Float32List>? _subscription;
  int? _capturingIndex;
  double _level = 0; // RMS of the most recent frames, 0..1.
  int _framesReceived = 0;

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
    _subscription?.cancel();
    _subscription = null;
    _capture?.stop();
    _capture = null;
    _capturingIndex = null;
    _level = 0;
    _framesReceived = 0;
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    const titleStyle = TextStyle(fontSize: 20, fontWeight: FontWeight.bold);
    final capture = _capture;
    return MaterialApp(
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
        ],
      ),
    );
  }
}
