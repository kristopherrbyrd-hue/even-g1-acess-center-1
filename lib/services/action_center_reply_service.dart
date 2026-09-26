import 'dart:convert';

import 'package:even_companion/models/action_center_reply_options.dart';
import 'package:even_companion/models/chat_message.dart';
import 'package:even_companion/services/chat_backend.dart';
import 'package:even_companion/services/openai_chat_backend.dart';

/// Produces the three silent quick-reply slots used by Action Center.
/// Voice Reply is deliberately not generated here; it is always UI slot #1.
class ActionCenterReplyService {
  ActionCenterReplyService({ChatBackend? backend})
      : _backend = backend ?? OpenAiChatBackend();

  final ChatBackend _backend;

  Future<ActionCenterReplyOptions> suggest({
    required String sender,
    required String latestMessage,
    List<String> recentContext = const <String>[],
  }) async {
    final context = recentContext
        .where((line) => line.trim().isNotEmpty)
        .take(3)
        .join('\n');
    final prompt = '''
Create exactly three very short reply options for smart glasses.
Incoming sender: $sender
Recent context:\n$context
Latest message: $latestMessage

Return JSON only with keys affirmative, negative, contextual.
Rules:
- affirmative must accept/agree/support when that intent makes conversational sense.
- negative must decline/disagree when that intent makes conversational sense.
- contextual is one useful alternative, question, or acknowledgement.
- Never invent facts, times, locations, actions already completed, or knowledge the user did not provide.
- Each reply must be natural, polite, and 2-8 words when possible; hard maximum 48 characters.
- Do not include quotation marks around the reply text beyond valid JSON syntax.
''';

    try {
      final raw = await _backend.send(
        messages: <ChatMessage>[
          ChatMessage(role: ChatRole.user, content: prompt),
        ],
      );
      final decoded = jsonDecode(_extractJsonObject(raw));
      if (decoded is! Map) throw const FormatException('Expected JSON object');
      return ActionCenterReplyOptions(
        affirmative: _clean(decoded['affirmative'], fallback: 'Sounds good'),
        negative: _clean(decoded['negative'], fallback: "Sorry, I can't"),
        contextual: _clean(decoded['contextual'], fallback: "I'll let you know"),
      );
    } catch (_) {
      // Quick replies must remain available even if the AI backend is offline.
      return const ActionCenterReplyOptions(
        affirmative: 'Sounds good',
        negative: "Sorry, I can't",
        contextual: "I'll let you know",
      );
    }
  }

  String _extractJsonObject(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) throw const FormatException('No JSON object');
    return raw.substring(start, end + 1);
  }

  String _clean(dynamic value, {required String fallback}) {
    if (value is! String || value.trim().isEmpty) return fallback;
    var text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length > 48) text = text.substring(0, 48).trimRight();
    return text;
  }
}
