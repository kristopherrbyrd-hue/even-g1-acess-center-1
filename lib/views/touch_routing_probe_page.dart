import 'dart:async';
import 'dart:convert';

import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/services/action_center_service.dart';
import 'package:even_companion/services/ble.dart';
import 'package:even_companion/services/proto.dart';
import 'package:even_companion/services/text_service.dart';
import 'package:flutter/material.dart';

/// Compare incoming BLE events while the same touches are performed on three
/// existing G1 display surfaces. No firmware or touch settings are changed.
class TouchRoutingProbePage extends StatefulWidget {
  const TouchRoutingProbePage({super.key});

  @override
  State<TouchRoutingProbePage> createState() => _TouchRoutingProbePageState();
}

class _TouchRoutingProbePageState extends State<TouchRoutingProbePage> {
  static const _modes = <String>['Firmware dashboard', 'Static text', 'Streaming text'];
  static const _actions = <String>[
    'Tap RIGHT once', 'Tap LEFT once', 'Tap RIGHT twice',
    'Tap LEFT twice', 'Hold RIGHT', 'Hold LEFT',
  ];
  final _startedAt = DateTime.now().toUtc();
  final _trials = <Map<String, Object?>>[];
  final _events = <Map<String, Object?>>[];
  StreamSubscription<BleReceive>? _subscription;
  int _mode = 0;
  int _action = 0;
  int _repeat = 1;
  bool _running = false;
  bool _baseline = false;
  bool _busy = false;
  bool _saving = false;
  bool _complete = false;
  String? _savedUri;
  String? _savedName;
  Map<String, Object?>? _trial;

  @override
  void initState() {
    super.initState();
    _subscription = BleManager.get().eventBleReceive.listen(_onPacket);
  }

  void _onPacket(BleReceive packet) {
    if (!_running || packet.data.isEmpty || packet.type == 'VoiceChunk' ||
        _events.length >= 5000) return;
    final at = DateTime.now().toUtc();
    _events.add({
      'mode': _modes[_mode], 'gesture': _actions[_action],
      'repeat': _repeat, 'phase': _baseline ? 'baseline' : 'action',
      'at': at.toIso8601String(),
      'elapsedMs': at.difference(_startedAt).inMilliseconds,
      'side': packet.lr, 'type': packet.type,
      'opcode': '0x${packet.data.first.toRadixString(16).padLeft(2, '0')}',
      'hex': packet.hexStringData(),
    });
    if (mounted) setState(() {});
  }

  Future<void> _enterMode() async {
    await Proto.stopStreamingText(sendFinalFrame: false);
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    if (_mode == 0) {
      if (ActionCenterService.enabled) await ActionCenterService.get.syncDashboard();
    } else if (_mode == 1) {
      await TextService.get.startSendText('TOUCH TEST\nStatic text screen\nUse phone for prompts');
    } else {
      await Proto.startStreamingText();
      await Proto.sendStreamingLine('TOUCH TEST - STREAM', line: 2, confirmed: true);
    }
    // These writes are outside both measured windows. Keep the HUD fixed
    // through every gesture on this surface.
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }

  Future<void> _tap() async {
    if (_busy || _complete) return;
    if (!BleManager.get().isConnected) {
      _error('Connect the glasses first.');
      return;
    }
    if (!_running) {
      setState(() => _busy = true);
      try {
        if (_action == 0 && _repeat == 1) await _enterMode();
        _trial = {
          'mode': _modes[_mode], 'gesture': _actions[_action], 'repeat': _repeat,
          'baselineStartedAt': DateTime.now().toUtc().toIso8601String(),
        };
        if (mounted) setState(() { _baseline = true; _running = true; });
      } catch (error) {
        _error('Could not show test surface: $error');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    final now = DateTime.now().toUtc().toIso8601String();
    if (_baseline) {
      _trial!['baselineEndedAt'] = now;
      _trial!['actionStartedAt'] = now;
      setState(() => _baseline = false);
      return;
    }
    _trial!['actionEndedAt'] = now;
    _trials.add(_trial!);
    setState(() {
      _running = false;
      if (_repeat == 1) {
        _repeat = 2;
      } else {
        _repeat = 1;
        _action++;
        if (_action == _actions.length) {
          _action = 0;
          _mode++;
          _complete = _mode == _modes.length;
        }
      }
    });
    if (_complete) {
      setState(() => _busy = true);
      await _restoreHud();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreHud() async {
    await Proto.stopStreamingText(sendFinalFrame: false);
    await TextService.get.stopTextSendingByOS();
    if (!BleManager.get().isConnected) return;
    await Proto.exit();
    if (ActionCenterService.enabled) await ActionCenterService.get.syncDashboard();
  }

  void _error(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    if (_trials.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final payload = const JsonEncoder.withIndent('  ').convert({
        'schema': 'even-g1-touch-routing-v1',
        'startedAt': _startedAt.toIso8601String(),
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'complete': _complete,
        'note': 'Static display per mode. Each trial has a quiet baseline and a tap-bounded action. BLE RX only; voice chunks omitted. Display mode writes occur outside trials.',
        'trials': _trials, 'events': _events,
      });
      final result = await BleManager.invokeMethod<Map<dynamic, dynamic>>(
          'saveGestureProbe', {'json': payload});
      if (!mounted) return;
      setState(() {
        _savedUri = result?['uri'] as String?;
        _savedName = result?['name'] as String?;
      });
      if (_savedUri == null) throw StateError('No saved file URI');
    } catch (error) {
      _error('Could not save test: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _share() async {
    if (_savedUri == null) return;
    try {
      await BleManager.invokeMethod<bool>('shareGestureProbe',
          {'uri': _savedUri, 'name': _savedName});
    } catch (error) {
      _error('Could not share test: $error');
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    if (!_complete) unawaited(_restoreHud());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = _complete ? 0 : _events.where((event) =>
        event['mode'] == _modes[_mode] && event['gesture'] == _actions[_action] &&
        event['repeat'] == _repeat && event['phase'] == (_baseline ? 'baseline' : 'action')).length;
    return Scaffold(
      appBar: AppBar(title: const Text('G1 Touch Routing Test'), actions: [
        if (_trials.isNotEmpty && !_complete)
          IconButton(tooltip: 'Save progress', icon: const Icon(Icons.save_alt),
              onPressed: _saving ? null : _save),
      ]),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _complete ? null : _tap,
        child: SizedBox.expand(child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(_complete ? 'Test complete' : _modes[_mode],
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 20),
            if (!_complete) ...[
              Text('${_actions[_action]}  •  $_repeat/2',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 20),
              Text(_busy ? 'Switching glasses display…' : !_running
                  ? 'Tap phone screen to start the quiet baseline.'
                  : _baseline
                      ? 'Look forward and keep still. Tap phone screen when ready.'
                      : 'Do the gesture. Then tap phone screen to finish.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              Text('$count received packets in this phase'),
              const SizedBox(height: 25),
              const Text('The display stays the same for each test. On the native dashboard, look up to show it. Left hold may start voice; right hold may record a QuickNote.',
                  textAlign: TextAlign.center),
            ] else ...[
              const Text('Save and share the JSON file for analysis.'),
              const SizedBox(height: 20),
              FilledButton(onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving…' : 'Save to Downloads')),
              if (_savedUri != null) ...[
                Text('Saved: $_savedName'),
                OutlinedButton(onPressed: _share, child: const Text('Share recording')),
              ],
            ],
          ]),
        )),
      ),
    );
  }
}
