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

  @override
  void initState() {
    super.initState();
    _devices = multichannel_capture.listInputDevices();
  }

  void _refresh() {
    setState(() {
      _devices = multichannel_capture.listInputDevices();
    });
  }

  @override
  Widget build(BuildContext context) {
    const titleStyle = TextStyle(fontSize: 20, fontWeight: FontWeight.bold);
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('multichannel_capture'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Re-scan devices',
              onPressed: _refresh,
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
            const Divider(height: 1),
            Expanded(
              child: _devices.isEmpty
                  ? const Center(child: Text('No input devices found'))
                  : ListView.builder(
                      itemCount: _devices.length,
                      itemBuilder: (context, i) {
                        final d = _devices[i];
                        return ListTile(
                          leading: Icon(
                            d.isDefault ? Icons.star : Icons.mic,
                          ),
                          title: Text(d.name),
                          subtitle: Text(
                            'index ${d.index} · '
                            '${d.channels == 0 ? 'any' : '${d.channels}'} ch'
                            '${d.isDefault ? ' · default' : ''}',
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
