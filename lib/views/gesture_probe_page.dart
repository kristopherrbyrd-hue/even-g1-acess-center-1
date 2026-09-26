import 'dart:async';
import 'dart:convert';

import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/services/action_center_service.dart';
import 'package:even_companion/services/ble.dart';
import 'package:even_companion/services/proto.dart';
import 'package:even_companion/services/text_service.dart';
import 'package:flutter/material.dart';

/// A guided diagnostic. Only the short instructions write to the glasses;
/// observed packets, phone taps, and results never issue a gesture command.
class GestureProbePage extends StatefulWidget {
  const GestureProbePage({super.key});

  @override
  State<GestureProbePage> createState() => _GestureProbePageState();
}

enum _ProbePhase { baseline, action, complete }

class _GestureProbePageState extends State<GestureProbePage> {
  static const _maxAttempts = 5;
  static const _prompts = <String>[
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
    'Hold both pads',
    'Tap left pad once',
    'Tap left pad twice',
    'Tap left pad three times',
    'Tap left pad four times',
    'Hold left pad (native Even AI may open)',
  ];

  StreamSubscription<BleReceive>? _subscription;
  final DateTime _sessionStart = DateTime.now().toUtc();
  final List<Map<String, Object?>> _attempts = [];
  final List<Map<String, Object?>> _events = [];
  final Map<String, int> _candidateRepeats = {};
  final Set<String> _allBaselineSignatures = {};
  int _promptIndex = 0;
  int _attemptNumber = 1;
  _ProbePhase _phase = _ProbePhase.baseline;
  bool _busy = true;
  bool _saving = false;
  String? _savedUri;
  String? _savedName;

  Map<String, Object?>? _currentAttempt;
  final Set<String> _baselineSignatures = {};
  final Set<String> _actionSignatures = {};

  @override
  void initState() {
    super.initState();
    _subscription = BleManager.get().eventBleReceive.listen(_onPacket);
    WidgetsBinding.instance.addPostFrameCallback((_) => _beginBaseline());
  }

  String _signature(BleReceive packet) =>
      '${packet.lr}:${packet.hexStringData()}';

  // Replies to our display writes and teardown are recorded, but cannot
  // persuade the recorder that a gesture has a reliable incoming signal.
  bool _isGestureCandidate(BleReceive packet) {
    if (packet.data.isEmpty) return false;
    return !{0x06, 0x0e, 0x18, 0x4e, 0x50}.contains(packet.data.first);
  }

  void _onPacket(BleReceive packet) {
    if (_busy || _phase == _ProbePhase.complete ||
        packet.type == 'VoiceChunk' || packet.data.isEmpty ||
        packet.data.first == 0x25 || _events.length >= 5000) return;
    final now = DateTime.now().toUtc();
    final signature = _signature(packet);
    _events.add({
      'prompt': _promptIndex + 1,
      'attempt': _attemptNumber,
      'phase': _phase.name,
      'at': now.toIso8601String(),
      'elapsedMs': now.difference(_sessionStart).inMilliseconds,
      'side': packet.lr,
      'type': packet.type,
      'opcode': '0x${packet.data.first.toRadixString(16).padLeft(2, '0')}',
      'hex': packet.hexStringData(),
    });
    if (_isGestureCandidate(packet)) {
      if (_phase == _ProbePhase.baseline) {
        _baselineSignatures.add(signature);
      } else {
        _actionSignatures.add(signature);
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _showHud(String message) async {
    if (!BleManager.get().isConnected) return;
    await TextService.get.startSendText(message);
  }

  Future<void> _beginBaseline() async {
    if (!mounted || _phase == _ProbePhase.complete) return;
    setState(() => _busy = true);
    _baselineSignatures.clear();
    _actionSignatures.clear();
    _currentAttempt = {
      'prompt': _promptIndex + 1,
      'action': _prompts[_promptIndex],
      'attempt': _attemptNumber,
    };
    try {
      await _showHud('Look directly forward\nTap phone screen\n$_attemptNumber/$_maxAttempts');
      await Future<void>.delayed(const Duration(milliseconds: 250));
    } catch (error) {
      if (mounted) _showError('Could not show baseline: $error');
    }
    if (mounted) {
      _currentAttempt!['baselineStartedAt'] = DateTime.now().toUtc().toIso8601String();
      setState(() { _phase = _ProbePhase.baseline; _busy = false; });
    }
  }

  Future<void> _onFullScreenTap() async {
    if (_busy || _phase == _ProbePhase.complete) return;
    if (!BleManager.get().isConnected) {
      _showError('Connect the glasses to continue.');
      return;
    }
    setState(() => _busy = true);
    final now = DateTime.now().toUtc();
    if (_phase == _ProbePhase.baseline) {
      _currentAttempt!['baselineEndedAt'] = now.toIso8601String();
      _allBaselineSignatures.addAll(_baselineSignatures);
      try {
        await _showHud('${_prompts[_promptIndex]}\nTap phone screen\nwhen done');
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (mounted) {
          _currentAttempt!['actionStartedAt'] = DateTime.now().toUtc().toIso8601String();
          setState(() { _phase = _ProbePhase.action; _busy = false; });
        }
      } catch (error) {
        if (mounted) { setState(() => _busy = false); _showError('Could not show prompt: $error'); }
      }
      return;
    }

    _currentAttempt!['actionEndedAt'] = now.toIso8601String();
    final candidates = _actionSignatures.difference(_allBaselineSignatures);
    final repeated = <String>[];
    for (final signature in candidates) {
      final count = (_candidateRepeats[signature] ?? 0) + 1;
      _candidateRepeats[signature] = count;
      if (count >= 2) repeated.add(signature);
    }
    final clear = repeated.isNotEmpty;
    _currentAttempt!['baselineCandidateSignatures'] = _baselineSignatures.toList();
    _currentAttempt!['actionCandidateSignatures'] = _actionSignatures.toList();
    _currentAttempt!['newCandidateSignatures'] = candidates.toList();
    _currentAttempt!['repeatedNonbaselineSignatures'] = repeated;
    _currentAttempt!['earlyStop'] = clear;
    _attempts.add(_currentAttempt!);
    if (clear || _attemptNumber >= _maxAttempts) {
      _promptIndex++;
      _attemptNumber = 1;
      _candidateRepeats.clear();
      _allBaselineSignatures.clear();
    } else {
      _attemptNumber++;
    }
    if (_promptIndex >= _prompts.length) {
      setState(() => _phase = _ProbePhase.complete);
      await TextService.get.stopTextSendingByOS();
      await Proto.exit();
      if (BleManager.get().isConnected && ActionCenterService.enabled) {
        await ActionCenterService.get.syncDashboard();
      }
      if (mounted) setState(() => _busy = false);
    } else {
      await _beginBaseline();
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    if (_saving || _attempts.isEmpty) return;
    setState(() => _saving = true);
    try {
      final json = const JsonEncoder.withIndent('  ').convert({
        'schema': 'even-g1-gesture-probe-v2',
        'startedAt': _sessionStart.toIso8601String(),
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'maxAttempts': _maxAttempts,
        'earlyStopRule': 'Same exact incoming side and bytes on at least two attempts, absent from their baselines; display response opcodes excluded.',
        'notes': 'Tap timestamps separate baseline and action. No packet can mean firmware handled the gesture locally. Voice chunks and heartbeats omitted.',
        'attempts': _attempts,
        'events': _events,
      });
      final result = await BleManager.invokeMethod<Map<dynamic, dynamic>>(
        'saveGestureProbe', {'json': json});
      if (!mounted) return;
      setState(() {
        _savedUri = result?['uri'] as String?;
        _savedName = result?['name'] as String?;
      });
      if (_savedUri == null) throw StateError('No saved file URI');
    } catch (error) {
      if (mounted) _showError('Could not save recording: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _share() async {
    if (_savedUri == null) return;
    try {
      await BleManager.invokeMethod<bool>('shareGestureProbe', {
        'uri': _savedUri, 'name': _savedName,
      });
    } catch (error) {
      if (mounted) _showError('Could not share recording: $error');
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    // Stop the diagnostic text only if it still owns the surface.
    if (_phase != _ProbePhase.complete) {
      unawaited(_leaveHud());
    }
    super.dispose();
  }

  Future<void> _leaveHud() async {
    await TextService.get.stopTextSendingByOS();
    if (!BleManager.get().isConnected) return;
    await Proto.exit();
    if (ActionCenterService.enabled) await ActionCenterService.get.syncDashboard();
  }

  @override
  Widget build(BuildContext context) {
    final complete = _phase == _ProbePhase.complete;
    final label = complete ? 'Recording complete' :
        _phase == _ProbePhase.baseline ? 'Look directly forward' : _prompts[_promptIndex];
    final instruction = complete ? 'Save and share the packet file below.' :
        _phase == _ProbePhase.baseline ? 'Tap anywhere to show the gesture.' :
        'Do the gesture, then tap anywhere.';
    final count = _events.where((e) => e['prompt'] == _promptIndex + 1 &&
        e['attempt'] == _attemptNumber && e['phase'] == _phase.name).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('G1 Gesture Recorder'),
        actions: [
          if (_attempts.isNotEmpty && !complete)
            IconButton(tooltip: 'Save progress', onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_alt)),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: complete ? null : _onFullScreenTap,
        child: SizedBox.expand(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(complete ? '${_prompts.length} gestures' :
                    'Gesture ${_promptIndex + 1}/${_prompts.length} • Attempt $_attemptNumber/$_maxAttempts'),
                const SizedBox(height: 28),
                Text(label, textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 22),
                Text(_busy ? 'Showing prompt on glasses…' : instruction,
                    textAlign: TextAlign.center),
                if (!complete) ...[
                  const SizedBox(height: 16),
                  Text('$count packets in this phase'),
                ],
                if (complete || _savedUri != null) ...[
                  const SizedBox(height: 30),
                  FilledButton(onPressed: _saving ? null : _save,
                      child: Text(_saving ? 'Saving…' : 'Save to Downloads')),
                  if (_savedUri != null) ...[
                    const SizedBox(height: 12),
                    Text('Saved: $_savedName'),
                    OutlinedButton(onPressed: _share, child: const Text('Share recording')),
                  ],
                ],
                if (!complete) ...[
                  const SizedBox(height: 26),
                  const Text('The whole screen is the tap target. Left hold may open native Even AI.',
                      textAlign: TextAlign.center),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
