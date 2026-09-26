import 'dart:async';
import 'dart:convert';

import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/services/ble.dart';
import 'package:flutter/material.dart';

/// Passive, guided capture of the packets the G1 actually sends to the phone.
/// It never changes the active mode or writes anything to the glasses.
class GestureProbePage extends StatefulWidget {
  const GestureProbePage({super.key});

  @override
  State<GestureProbePage> createState() => _GestureProbePageState();
}

class _GestureProbePageState extends State<GestureProbePage> {
  static const prompts = <String>[
    'Keep still and look forward (baseline)',
    'Look up',
    'Look forward again',
    'Look right quickly',
    'Tilt your head right',
    'Look left quickly',
    'Tilt your head left',
    'Tilt your head up',
    'Tilt your head down',
    'Tap right pad once',
    'Tap right pad twice',
    'Tap right pad three times',
    'Tap right pad four times',
    'Hold right pad',
    'Tap left pad once',
    'Tap left pad twice',
    'Tap left pad three times',
    'Tap left pad four times',
    'Hold left pad (may open native Even AI)',
    'Hold both pads',
  ];

  StreamSubscription<BleReceive>? _subscription;
  final List<Map<String, Object?>> _trials = [];
  final List<Map<String, Object?>> _events = [];
  final DateTime _sessionStart = DateTime.now().toUtc();
  int _index = 0;
  bool _capturing = false;
  bool _saving = false;
  String? _savedUri;
  String? _savedName;

  @override
  void initState() {
    super.initState();
    _subscription = BleManager.get().eventBleReceive.listen(_onPacket);
  }

  void _onPacket(BleReceive packet) {
    if (!_capturing || packet.type == 'VoiceChunk' || packet.data.isEmpty) return;
    if (_events.length >= 5000) return;
    // Heartbeats are periodic background traffic and hide the useful events.
    if (packet.data.first == 0x25) return;
    final now = DateTime.now().toUtc();
    _events.add({
      'trial': _index + 1,
      'at': now.toIso8601String(),
      'elapsedMs': now.difference(_sessionStart).inMilliseconds,
      'side': packet.lr,
      'type': packet.type,
      'opcode': '0x${packet.data.first.toRadixString(16).padLeft(2, '0')}',
      'hex': packet.hexStringData(),
    });
    if (mounted) setState(() {});
  }

  void _start() {
    if (!BleManager.get().isConnected) return;
    setState(() {
      _capturing = true;
      _trials.add({
        'number': _index + 1,
        'prompt': prompts[_index],
        'startedAt': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  void _finish({bool skipped = false}) {
    setState(() {
      if (_capturing) {
        _trials.last['endedAt'] = DateTime.now().toUtc().toIso8601String();
        _trials.last['skipped'] = skipped;
      } else {
        _trials.add({
          'number': _index + 1,
          'prompt': prompts[_index],
          'skipped': true,
        });
      }
      _capturing = false;
      _index++;
    });
  }

  Future<void> _save() async {
    if (_saving || _trials.isEmpty) return;
    setState(() => _saving = true);
    try {
      final content = const JsonEncoder.withIndent('  ').convert({
        'schema': 'even-g1-gesture-probe-v1',
        'startedAt': _sessionStart.toIso8601String(),
        'endedAt': DateTime.now().toUtc().toIso8601String(),
        'notes': 'Passive incoming BLE control packets. Missing events may be handled locally by G1 firmware. Voice chunks and periodic heartbeats excluded.',
        'trials': _trials,
        'events': _events,
      });
      final result = await BleManager.invokeMethod<Map<dynamic, dynamic>>(
        'saveGestureProbe',
        {'json': content},
      );
      if (!mounted) return;
      setState(() {
        _savedUri = result?['uri'] as String?;
        _savedName = result?['name'] as String?;
      });
      if (_savedUri == null) throw StateError('No saved file URI');
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save recording: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _share() async {
    final uri = _savedUri;
    if (uri == null) return;
    await BleManager.invokeMethod<bool>('shareGestureProbe', {
      'uri': uri,
      'name': _savedName,
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final done = _index >= prompts.length;
    final currentEvents = _events.where((e) => e['trial'] == _index + 1).length;
    return Scaffold(
      appBar: AppBar(title: const Text('G1 Gesture Recorder')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Follow each prompt while wearing the glasses. Tap Start, do the action, then tap Done. Repeat a gesture a few times if useful. This screen only listens to incoming packets.'),
          const SizedBox(height: 20),
          Text(done ? 'All prompts complete' : 'Prompt ${_index + 1} of ${prompts.length}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          if (!done) Text(prompts[_index], style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 20),
          Text(_capturing ? 'Recording • $currentEvents packets' : '${_events.length} packets captured total'),
          const SizedBox(height: 16),
          if (!BleManager.get().isConnected)
            const Text('Connect the glasses before recording.'),
          if (!done && !_capturing)
            FilledButton(onPressed: BleManager.get().isConnected ? _start : null, child: const Text('Start this prompt')),
          if (!done && _capturing)
            FilledButton(onPressed: () => _finish(), child: const Text('Done with this prompt')),
          if (!done)
            TextButton(onPressed: () => _finish(skipped: true), child: const Text('Skip this prompt')),
          if (_trials.isNotEmpty) ...[
            const SizedBox(height: 20),
            FilledButton.tonal(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving...' : 'Save recording to Downloads')),
          ],
          if (_savedUri != null) ...[
            const SizedBox(height: 8),
            Text('Saved: $_savedName'),
            OutlinedButton(onPressed: _share, child: const Text('Share recording')),
          ],
          const SizedBox(height: 20),
          const Text('Some taps and gaze movements may be handled entirely by G1 firmware. A quiet trial is useful evidence too. Left hold may activate the native Even AI feature.'),
        ],
      ),
    );
  }
}
