import 'package:even_companion/models/companion_notification.dart';

enum ActionCenterCardKind {
  message,
  email,
  missedCall,
  notification,
}

class ActionCenterCard {
  const ActionCenterCard({
    required this.id,
    required this.kind,
    required this.source,
    required this.sender,
    required this.body,
    required this.notificationKey,
    required this.packageName,
    required this.postedAt,
    required this.canReply,
  });

  final String id;
  final ActionCenterCardKind kind;
  final String source;
  final String sender;
  final String body;
  final String notificationKey;
  final String packageName;
  final DateTime postedAt;
  final bool canReply;

  factory ActionCenterCard.fromNotification(CompanionNotification notification) {
    final package = notification.packageName.toLowerCase();
    final source = notification.source.trim();
    final sender = notification.title.trim().isNotEmpty
        ? notification.title.trim()
        : source;
    final body = _cleanBody(notification, sender);
    final kind = _kindFor(package, notification.category, source);
    return ActionCenterCard(
      id: notification.key,
      kind: kind,
      source: source,
      sender: sender,
      body: body,
      notificationKey: notification.key,
      packageName: notification.packageName,
      postedAt: notification.postedAt,
      canReply: notification.canReply,
    );
  }

  static ActionCenterCardKind _kindFor(
    String package,
    String category,
    String source,
  ) {
    final normalizedSource = source.toLowerCase();
    if (category.toLowerCase() == 'call') {
      return ActionCenterCardKind.missedCall;
    }
    if (package.contains('gm') ||
        package.contains('gmail') ||
        normalizedSource == 'gmail') {
      return ActionCenterCardKind.email;
    }
    if (category.toLowerCase() == 'msg' ||
        category.toLowerCase() == 'message' ||
        package.contains('messag') ||
        package.contains('whatsapp') ||
        package.contains('signal')) {
      return ActionCenterCardKind.message;
    }
    return ActionCenterCardKind.notification;
  }

  static String _cleanBody(
    CompanionNotification notification,
    String sender,
  ) {
    final candidates = <String>[
      notification.text,
      notification.bigText,
      notification.message,
    ];
    var value = candidates.firstWhere(
      (candidate) => candidate.trim().isNotEmpty,
      orElse: () => 'Open your phone for details',
    ).trim();
    final prefix = '$sender:';
    if (value.startsWith(prefix)) {
      value = value.substring(prefix.length).trim();
    }
    return value;
  }
}
