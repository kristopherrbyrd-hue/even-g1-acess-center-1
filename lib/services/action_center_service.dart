import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/models/action_center_card.dart';
import 'package:even_companion/models/companion_notification.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/action_center_reply_service.dart';
import 'package:even_companion/models/action_center_reply_options.dart';
import 'package:even_companion/services/notification_policy.dart';
import 'package:even_companion/services/proto.dart';
import 'package:even_companion/services/text_service.dart';
import 'package:even_companion/services/openai_transcription_service.dart';
import 'dart:io';

/// Owns the notification-backed Action Center surface.
///
/// v0.2 uses the firmware-native Calendar secondary pane as a non-destructive
/// carrier for notification cards. Unlike 0x1E QuickNote records, these cards
/// do not overwrite the user's saved QuickNotes. The firmware owns single-tap
/// paging; 0x22 status packets tell us which page is visible.
class ActionCenterService {
  ActionCenterService._();
  static final ActionCenterService get = ActionCenterService._();

  static const int maxDashboardCards = 4;
  static const bool enabled = true;

  final List<ActionCenterCard> _cards = <ActionCenterCard>[];
  int _visibleIndex = 0;
  bool _dashboardVisible = false;
  bool _detailVisible = false;
  _ActionCenterView _view = _ActionCenterView.dashboard;
  int _menuIndex = 0;
  ActionCenterReplyOptions? _replyOptions;
  String? _pendingReply;
  String? _activeCardId;
  bool _dashboardSyncPending = false;
  final ActionCenterReplyService _replyService = ActionCenterReplyService();
  final OpenAiTranscriptionService _transcriptionService = OpenAiTranscriptionService();
  bool _voiceRecording = false;
  bool _virtualMode = false;
  List<ActionCenterCard>? _liveCardsBeforeVirtual;

  List<ActionCenterCard> get cards => List.unmodifiable(_cards);
  // Virtual HUD hooks. These drive the same state machine without BLE.
  String get virtualViewName => _view.name;
  bool get virtualVoiceRecording => _voiceRecording;

  void virtualReset() {
    if (!_virtualMode) _liveCardsBeforeVirtual = List<ActionCenterCard>.of(_cards);
    _virtualMode = true;
    _cards
      ..clear()
      ..addAll(<ActionCenterCard>[
        ActionCenterCard(id: 'sim-msg-1', kind: ActionCenterCardKind.message, source: 'Messages', sender: 'Jillian', body: 'Can you grab milk and eggs on your way home?', notificationKey: 'sim-msg-1', packageName: 'sim.messages', postedAt: DateTime.now(), canReply: true),
        ActionCenterCard(id: 'sim-mail-1', kind: ActionCenterCardKind.email, source: 'Gmail', sender: 'Nancy', body: 'Finished reading Chapter 17. I left a few notes for you.', notificationKey: 'sim-mail-1', packageName: 'sim.gmail', postedAt: DateTime.now(), canReply: true),
        ActionCenterCard(id: 'sim-info-1', kind: ActionCenterCardKind.notification, source: 'Amazon', sender: 'Amazon', body: 'Your package has been delivered.', notificationKey: 'sim-info-1', packageName: 'sim.amazon', postedAt: DateTime.now(), canReply: false),
      ]);
    _visibleIndex = 0; _dashboardVisible = true; _detailVisible = false;
    _view = _ActionCenterView.dashboard; _menuIndex = 0; _activeCardId = null;
    _pendingReply = null; _replyOptions = null; _voiceRecording = false;
  }

  void virtualAddIncoming() {
    _cards.insert(0, ActionCenterCard(id: 'sim-new-${DateTime.now().millisecondsSinceEpoch}', kind: ActionCenterCardKind.message, source: 'Messages', sender: 'New message', body: 'This arrived while you were using Action Center.', notificationKey: 'sim-new', packageName: 'sim.messages', postedAt: DateTime.now(), canReply: true));
    if (_cards.length > maxDashboardCards) _cards.removeLast();
    if (!ownsInteractiveDisplay) _visibleIndex = 0;
  }

  void virtualRemoveActive() {
    final id = _activeCardId;
    if (id != null) _cards.removeWhere((c) => c.id == id);
  }

  Future<void> virtualRightTap() async {
    if (_view == _ActionCenterView.dashboard) { if (_cards.isNotEmpty) _visibleIndex = (_visibleIndex + 1) % _cards.length; return; }
    _virtualMove(1);
  }
  Future<void> virtualLeftTap() async {
    if (_view == _ActionCenterView.dashboard) { if (_cards.isNotEmpty) _visibleIndex = (_visibleIndex - 1 + _cards.length) % _cards.length; return; }
    _virtualMove(-1);
  }
  void _virtualMove(int direction) {
    final count = _view == _ActionCenterView.confirm ? 2 :
        (_view == _ActionCenterView.replyMenu ? _quickReplies.length + 1 : 1);
    if (count > 1) _menuIndex = (_menuIndex + direction + count) % count;
  }
  Future<void> virtualSelect() async {
    if (_view == _ActionCenterView.dashboard) { final card = visibleCard; if (card != null) { _activeCardId = card.id; _detailVisible = true; _view = _ActionCenterView.detail; _menuIndex = 0; } return; }
    if (_view == _ActionCenterView.detail) {
      final card = visibleCard; if (card == null || !card.canReply) return;
      _replyOptions = const ActionCenterReplyOptions(affirmative: 'Yep, I can do that', negative: "Sorry, I can't tonight", contextual: 'What time were you thinking?');
      _view = _ActionCenterView.replyMenu; _menuIndex = 0; return;
    }
    if (_view == _ActionCenterView.replyMenu && _menuIndex == 0) { _voiceRecording = true; _view = _ActionCenterView.voiceListening; return; }
    if (_view == _ActionCenterView.voiceListening) { _voiceRecording = false; _pendingReply = 'I can grab milk. Do you need anything else?'; _view = _ActionCenterView.confirm; _menuIndex = 0; return; }
    if (_view == _ActionCenterView.replyMenu) {
      final replies = _quickReplies;
      if (_menuIndex > 0 && _menuIndex <= replies.length) {
        _pendingReply = replies[_menuIndex - 1];
        _view = _ActionCenterView.confirm; _menuIndex = 0;
      }
      return;
    }
    if (_view == _ActionCenterView.confirm) {
      if (_menuIndex == 0 && visibleCard != null) _view = _ActionCenterView.sent;
      else { _view = _ActionCenterView.replyMenu; _menuIndex = 0; }
      return;
    }
    if (_view == _ActionCenterView.sent) { virtualExit(); return; }
  }
  Future<void> virtualBack() async {
    if (_view == _ActionCenterView.dashboard) return;
    if (_view == _ActionCenterView.voiceListening) { _voiceRecording = false; _view = _ActionCenterView.replyMenu; _menuIndex = 0; return; }
    if (_view == _ActionCenterView.detail || _view == _ActionCenterView.sent) { virtualExit(); return; }
    if (_view == _ActionCenterView.confirm) { _view = _ActionCenterView.replyMenu; _menuIndex = 0; return; }
    if (_view == _ActionCenterView.replyMenu) { _view = _ActionCenterView.detail; _menuIndex = 0; return; }
  }
  void virtualExit() { _view = _ActionCenterView.dashboard; _activeCardId = null; _menuIndex = 0; _pendingReply = null; _replyOptions = null; _voiceRecording = false; _dashboardVisible = true; }

  Future<void> leaveVirtualMode() async {
    if (!_virtualMode) return;
    virtualExit();
    _cards..clear()..addAll(_liveCardsBeforeVirtual ?? const <ActionCenterCard>[]);
    _liveCardsBeforeVirtual = null;
    _virtualMode = false;
    _dashboardVisible = false;
  }

  String get virtualDisplayText {
    final card = visibleCard;
    if (_view == _ActionCenterView.dashboard) {
      if (card == null) return 'ACTION CENTER\n\nNo new notifications\n\nHold to open';
      return '${card.source.toUpperCase()}                         ${_visibleIndex + 1}/${_cards.length}\n\n${_cardTitle(card)}\n${_truncate(card.body, 74)}';
    }
    if (card == null) return 'Notification no longer available\n\nBack to exit';
    if (_view == _ActionCenterView.detail) return '${_cardTitle(card)}\n\n${card.body}\n\n${card.canReply ? 'Hold: Reply' : 'No quick reply'}';
    if (_view == _ActionCenterView.replyMenu) {
      final replies=_quickReplies; final lines=<String>['REPLY TO ${_truncate(_cardTitle(card).toUpperCase(),20)}'];
      lines.add('${_menuIndex==0?'>':' '} Voice reply');
      for (var i=0;i<replies.length;i++) lines.add('${_menuIndex==i+1?'>':' '} ${_truncate(replies[i],42)}');
      return lines.join('\n');
    }
    if (_view == _ActionCenterView.voiceListening) return 'REPLY TO ${_truncate(_cardTitle(card).toUpperCase(),18)}\n\n* LISTENING *\n\nHold again when done\nBack: cancel';
    if (_view == _ActionCenterView.confirm) return 'SEND TO ${_truncate(_cardTitle(card).toUpperCase(),18)}?\n"${_truncate(_pendingReply ?? '',52)}"\n\n${_menuIndex==0?'>':' '} Send\n${_menuIndex==1?'>':' '} Back';
    if (_view == _ActionCenterView.sent) return 'Sent\n\nHold to return';
    return 'Transcribing...';
  }

  int get visibleIndex => _visibleIndex;
  bool get dashboardVisible => _dashboardVisible;
  bool get detailVisible => _detailVisible;
  bool get ownsInteractiveDisplay => _view != _ActionCenterView.dashboard;

  ActionCenterCard? get visibleCard {
    if (_activeCardId != null) {
      for (final card in _cards) {
        if (card.id == _activeCardId) return card;
      }
      return null;
    }
    if (_cards.isEmpty) return null;
    final index = _visibleIndex.clamp(0, _cards.length - 1);
    return _cards[index];
  }

  Future<void> hydrate(List<CompanionNotification> notifications) async {
    if (_virtualMode) { _liveCardsBeforeVirtual = notifications.where(_accepts).map(ActionCenterCard.fromNotification).take(maxDashboardCards).toList(); return; }
    _cards
      ..clear()
      ..addAll(notifications.where(_accepts).map(ActionCenterCard.fromNotification).take(maxDashboardCards));
    _visibleIndex = 0;
    await _syncDashboardOrDefer();
  }

  Future<void> ingest(CompanionNotification notification) async {
    if (_virtualMode) { if (_accepts(notification)) { final live = _liveCardsBeforeVirtual ??= []; live.removeWhere((c) => c.notificationKey == notification.key); live.insert(0, ActionCenterCard.fromNotification(notification)); if (live.length > maxDashboardCards) live.removeLast(); } return; }
    if (!_accepts(notification)) return;
    _cards.removeWhere((card) => card.notificationKey == notification.key);
    _cards.insert(0, ActionCenterCard.fromNotification(notification));
    if (_cards.length > maxDashboardCards) {
      _cards.removeRange(maxDashboardCards, _cards.length);
    }
    _visibleIndex = 0;
    await _syncDashboardOrDefer();
  }

  Future<void> remove(String notificationKey) async {
    if (_virtualMode) { _liveCardsBeforeVirtual?.removeWhere((c) => c.notificationKey == notificationKey); return; }
    final before = _cards.length;
    _cards.removeWhere((card) => card.notificationKey == notificationKey);
    if (_visibleIndex >= _cards.length) _visibleIndex = 0;
    if (_cards.length != before) await _syncDashboardOrDefer();
  }

  Future<bool> reply(ActionCenterCard card, String text) async {
    if (_virtualMode) return false;
    if (!card.canReply || text.trim().isEmpty) return false;
    final ok = await BleManager.invokeMethod<bool>(
          'replyNotification',
          <String, String>{'key': card.notificationKey, 'text': text.trim()},
        ) ??
        false;
    AppLog.info('${DateTime.now()} Action Center reply -> source=${card.source} ok=$ok', tag: 'ActionCenter');
    return ok;
  }


  Future<void> _syncDashboardOrDefer() async {
    if (ownsInteractiveDisplay) {
      _dashboardSyncPending = true;
      return;
    }
    await syncDashboard();
  }

  /// Push cards into a firmware-native dashboard pane, then select that pane.
  Future<void> syncDashboard() async {
    if (_virtualMode) return;
    final records = _cards.map((card) {
      final title = _truncate(_cardTitle(card), 38);
      final subtitle = _truncate(card.source, 24);
      final body = _truncate(card.body, 72);
      return (title: title, subtitle: subtitle, body: body);
    }).toList();

    await Proto.setDashboardCalendarCards(records);
    // Ensure head-up opens the firmware dashboard so its local tap carousel
    // remains in control. This is a persisted glasses setting.
    await Proto.setHeadUpMode(0x00);
    // Full dashboard + Calendar secondary pane. The left-side next-event HUD
    // is separate; this changes only the pageable secondary pane.
    await Proto.setDashboardPane(mode: 0, pane: 3);
  }

  /// Consume firmware dashboard status. For event 0x02, byte 7 is the
  /// 1-based pane page number. For event 0x01 (head-up), byte 9 is page.
  void handleDashboardStatus(List<int> data) {
    if (_virtualMode) return;
    if (data.length < 5 || data[0] != 0x22) return;
    final event = data[4];
    int? pane;
    int? page;
    if (event == 0x02 && data.length >= 8) {
      _dashboardVisible = true;
      pane = data[6];
      page = data[7];
    } else if (event == 0x01 && data.length >= 10) {
      _dashboardVisible = true;
      pane = data[8];
      page = data[9];
    }
    if (pane == 3 && page != null && page > 0 && _cards.isNotEmpty) {
      _visibleIndex = (page - 1).clamp(0, _cards.length - 1);
      AppLog.info(
        '${DateTime.now()} Action Center visible card ${_visibleIndex + 1}/${_cards.length}',
        tag: 'ActionCenter',
      );
    }
  }

  void handleDashboardBoundary({required bool open}) {
    if (_virtualMode) return;
    _dashboardVisible = open;
    if (!open && _view == _ActionCenterView.dashboard) _detailVisible = false;
  }

  /// Right long-hold is Select while Action Center owns either the dashboard
  /// pane or its interactive text surface.
  Future<bool> consumeRightHold() async {
    if (_virtualMode) return false;
    if (_view == _ActionCenterView.dashboard) {
      if (!_dashboardVisible) return false;
      final card = visibleCard;
      if (card == null) return false;
      _detailVisible = true;
      _activeCardId = card.id;
      _view = _ActionCenterView.detail;
      _menuIndex = 0;
      _replyOptions = null;
      _pendingReply = null;
      await _render();
      AppLog.info(
        '${DateTime.now()} Action Center selected index=$_visibleIndex key=${card.notificationKey}',
        tag: 'ActionCenter',
      );
      return true;
    }

    final card = visibleCard;
    if (card == null) {
      await TextService.get.startSendText('Notification no longer available\nHold to exit');
      _view = _ActionCenterView.sent;
      return true;
    }
    switch (_view) {
      case _ActionCenterView.detail:
        if (!card.canReply) return true;
        _replyOptions ??= await _replyService.suggest(
          sender: card.sender,
          latestMessage: card.body,
        );
        _view = _ActionCenterView.replyMenu;
        _menuIndex = 0;
        await _render();
        return true;
      case _ActionCenterView.replyMenu:
        // Voice is always item 0. Silent AI replies follow it.
        if (_menuIndex == 0) {
          await _startVoiceReply();
          return true;
        }
        final replies = _quickReplies;
        if (replies.isEmpty) return true;
        final replyIndex = (_menuIndex - 1).clamp(0, replies.length - 1);
        _pendingReply = replies[replyIndex];
        _view = _ActionCenterView.confirm;
        _menuIndex = 0;
        await _render();
        return true;
      case _ActionCenterView.voiceListening:
        await _finishVoiceReply();
        return true;
      case _ActionCenterView.transcribing:
        return true;
      case _ActionCenterView.confirm:
        if (_menuIndex == 0 && _pendingReply != null) {
          final ok = await reply(card, _pendingReply!);
          await TextService.get.startSendText(ok ? 'Sent' : 'Send failed\nOpen phone');
          if (ok) {
            _view = _ActionCenterView.sent;
          }
        } else {
          _view = _ActionCenterView.replyMenu;
          _menuIndex = 0;
          await _render();
        }
        return true;
      case _ActionCenterView.sent:
        await exitInteractive();
        return true;
      case _ActionCenterView.dashboard:
        return false;
    }
  }

  /// F5 01 becomes local menu navigation only after Action Center has opened
  /// its text surface. Left = previous, right = next.
  Future<bool> consumeFeatureTap(String side) async {
    if (_virtualMode) return false;
    if (!ownsInteractiveDisplay) return false;
    final count = _view == _ActionCenterView.confirm ? 2 :
        (_view == _ActionCenterView.replyMenu ? _quickReplies.length + 1 : 1);
    if (count <= 1) return true;
    if (side == 'L') {
      _menuIndex = (_menuIndex - 1 + count) % count;
    } else {
      _menuIndex = (_menuIndex + 1) % count;
    }
    await _render();
    return true;
  }

  /// F5 00 is Back while Action Center owns an interactive surface.
  Future<bool> consumeBack() async {
    if (_virtualMode) return false;
    if (!ownsInteractiveDisplay) return false;
    switch (_view) {
      case _ActionCenterView.confirm:
        _view = _ActionCenterView.replyMenu;
        _menuIndex = 0;
        await _render();
        break;
      case _ActionCenterView.voiceListening:
        await _cancelVoiceReply();
        _view = _ActionCenterView.replyMenu;
        _menuIndex = 0;
        await _render();
        break;
      case _ActionCenterView.transcribing:
        // Transcription is short-lived and cannot be safely interrupted after
        // the recorder has handed us the temp file. Ignore Back until it ends.
        break;
      case _ActionCenterView.replyMenu:
        _view = _ActionCenterView.detail;
        _menuIndex = 0;
        await _render();
        break;
      case _ActionCenterView.detail:
      case _ActionCenterView.sent:
        await exitInteractive();
        break;
      case _ActionCenterView.dashboard:
        return false;
    }
    return true;
  }

  Future<void> exitInteractive() async {
    if (_virtualMode) return;
    _view = _ActionCenterView.dashboard;
    _detailVisible = false;
    _menuIndex = 0;
    _pendingReply = null;
    _activeCardId = null;
    if (_voiceRecording) await _cancelVoiceReply();
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    // Always refresh after an interaction. A successful reply commonly
    // changes/removes the Android notification, and the dashboard should
    // immediately reflect the current queue rather than stale text.
    _dashboardSyncPending = false;
    await syncDashboard();
  }

  List<String> get _quickReplies {
    final options = _replyOptions;
    if (options == null) return const <String>[];
    return <String>[options.affirmative, options.negative, options.contextual];
  }

  Future<void> _render() async {
    final card = visibleCard;
    if (card == null) return;
    switch (_view) {
      case _ActionCenterView.detail:
        final footer = card.canReply ? '\n\nHold: Reply' : '\n\nNo quick reply';
        await TextService.get.startSendText('${_cardTitle(card)}\n${card.body}$footer');
        break;
      case _ActionCenterView.replyMenu:
        final replies = _quickReplies;
        final lines = <String>['REPLY TO ${_truncate(_cardTitle(card).toUpperCase(), 20)}'];
        lines.add('${_menuIndex == 0 ? '>' : ' '} Voice reply');
        for (var i = 0; i < replies.length; i++) {
          final menuPosition = i + 1;
          lines.add('${menuPosition == _menuIndex ? '>' : ' '} ${_truncate(replies[i], 42)}');
        }
        lines.add('L/R tap: move  Hold: select');
        await TextService.get.startSendText(lines.join('\n'));
        break;
      case _ActionCenterView.confirm:
        final text = _pendingReply ?? '';
        await TextService.get.startSendText(
          'SEND TO ${_truncate(_cardTitle(card).toUpperCase(), 18)}?\n'
          '"${_truncate(text, 52)}"\n\n'
          '${_menuIndex == 0 ? '>' : ' '} Send\n'
          '${_menuIndex == 1 ? '>' : ' '} Back',
        );
        break;
      case _ActionCenterView.voiceListening:
        await TextService.get.startSendText(
          'REPLY TO ${_truncate(_cardTitle(card).toUpperCase(), 18)}\n\n'
          '* LISTENING *\n\nHold again when done\nBack: cancel',
        );
        break;
      case _ActionCenterView.transcribing:
        await TextService.get.startSendText('Transcribing...');
        break;
      case _ActionCenterView.sent:
        await TextService.get.startSendText('Sent\nHold to return');
        break;
      case _ActionCenterView.dashboard:
        break;
    }
  }

  Future<void> _startVoiceReply() async {
    if (_voiceRecording) return;
    final started = await BleManager.invokeMethod<bool>('startGlassesCapture');
    if (started != true) {
      await TextService.get.startSendText('Mic start failed\nBack to replies');
      return;
    }
    final (_, micStarted) = await Proto.micOn(lr: 'R');
    if (!micStarted) {
      await BleManager.invokeMethod('cancelGlassesCapture');
      await TextService.get.startSendText('Mic start failed\nBack to replies');
      return;
    }
    _voiceRecording = true;
    _view = _ActionCenterView.voiceListening;
    await _render();
  }

  Future<void> _finishVoiceReply() async {
    if (!_voiceRecording) return;
    _voiceRecording = false;
    _view = _ActionCenterView.transcribing;
    await _render();
    String? tempPath;
    try {
      final raw = await BleManager.invokeMethod<Map<dynamic, dynamic>>(
        'stopGlassesCaptureToTemp',
      );
      tempPath = raw?['localPath'] as String?;
      await TextService.get.stopTextSendingByOS();
      await Proto.exit();
      if (tempPath == null || tempPath.isEmpty) {
        throw const ChatTranscriptionException('No recorded audio to transcribe');
      }
      final transcript = (await _transcriptionService.transcribe(tempPath)).trim();
      if (transcript.isEmpty) {
        _view = _ActionCenterView.replyMenu;
        _menuIndex = 0;
        await TextService.get.startSendText("Didn't catch that\nHold Voice reply to retry");
        return;
      }
      _pendingReply = transcript;
      _view = _ActionCenterView.confirm;
      _menuIndex = 0;
      await _render();
    } catch (error) {
      AppLog.error('${DateTime.now()} voice reply failed: $error', tag: 'ActionCenter');
      _view = _ActionCenterView.replyMenu;
      _menuIndex = 0;
      await TextService.get.startSendText('Voice reply failed\nUse a quick reply or retry');
    } finally {
      if (tempPath != null && tempPath.isNotEmpty) {
        try { await File(tempPath).delete(); } catch (_) {}
      }
    }
  }

  Future<void> _cancelVoiceReply() async {
    if (!_voiceRecording) return;
    _voiceRecording = false;
    await BleManager.invokeMethod('cancelGlassesCapture');
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
  }

  bool _accepts(CompanionNotification notification) {
    final disposition = NotificationPolicy.classify(notification);
    if (disposition == NotificationDisposition.blocked ||
        disposition == NotificationDisposition.suppressed ||
        disposition == NotificationDisposition.mediaAbsorbed ||
        disposition == NotificationDisposition.callAbsorbed) {
      return false;
    }
    final package = notification.packageName.toLowerCase();
    if (package.contains('calendar')) return false;
    return notification.title.trim().isNotEmpty ||
        notification.text.trim().isNotEmpty ||
        notification.message.trim().isNotEmpty;
  }

  String _cardTitle(ActionCenterCard card) {
    final sender = card.sender.trim();
    return sender.isEmpty ? card.source : sender;
  }

  String _truncate(String value, int maxChars) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxChars) return normalized;
    return '${normalized.substring(0, maxChars - 1).trimRight()}…';
  }
}


enum _ActionCenterView { dashboard, detail, replyMenu, voiceListening, transcribing, confirm, sent }
