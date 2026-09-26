import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:even_companion/models/chat_message.dart';
import 'package:even_companion/services/app_settings_store.dart';
import 'package:even_companion/services/chat_backend.dart';
import 'package:even_companion/services/openai_transcription_service.dart';

/// The left-hold trial uses one Gemini key for both speech and answers.
class GeminiGlassesService {
  static const _url =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent';
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 60),
    sendTimeout: const Duration(seconds: 60),
  ));

  String get _key => AppSettingsStore.get.geminiApiKey.trim();

  Future<String> transcribe(String filePath) async {
    if (_key.isEmpty) {
      throw const ChatTranscriptionException('Add a Gemini API key in Settings',
          kind: ChatTranscriptionErrorKind.auth);
    }
    final file = File(filePath);
    if (!await file.exists()) {
      throw const ChatTranscriptionException('Recorded audio file not found');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > 14 * 1024 * 1024) {
      throw const ChatTranscriptionException('Recording is too long');
    }
    try {
      return await _generate({
        'contents': [
          {'parts': [
            {'text': 'Transcribe only the spoken words in this audio. Return only the transcript.'},
            {'inlineData': {'mimeType': 'audio/wav', 'data': base64Encode(bytes)}}
          ]}
        ]
      });
    } on ChatBackendException catch (e) {
      throw ChatTranscriptionException(e.message,
          kind: e.kind == ChatBackendErrorKind.auth
              ? ChatTranscriptionErrorKind.auth
              : e.kind == ChatBackendErrorKind.timeout
                  ? ChatTranscriptionErrorKind.timeout
                  : e.kind == ChatBackendErrorKind.network
                      ? ChatTranscriptionErrorKind.network
                      : ChatTranscriptionErrorKind.generic);
    }
  }

  Future<String> answer(List<ChatMessage> messages) async {
    if (_key.isEmpty) {
      throw const ChatBackendException('Add a Gemini API key in Settings',
          kind: ChatBackendErrorKind.auth);
    }
    return _generate({
      'systemInstruction': {'parts': [
        {'text': 'Answer concisely for a small smart glasses display. Use short sentences and plain text.'}
      ]},
      'contents': messages.map((message) => {
        'role': message.role == ChatRole.user ? 'user' : 'model',
        'parts': [{'text': message.content}]
      }).toList(),
      'generationConfig': {'maxOutputTokens': 400},
    });
  }

  Future<String> _generate(Map<String, dynamic> body) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(_url,
          data: body,
          options: Options(headers: {'x-goog-api-key': _key}));
      final candidates = response.data?['candidates'] as List<dynamic>?;
      final content = candidates?.firstOrNull?['content'] as Map<String, dynamic>?;
      final parts = content?['parts'] as List<dynamic>?;
      final result = parts?.map((part) => part['text'] as String? ?? '').join('\n').trim() ?? '';
      if (result.isEmpty) {
        throw const ChatBackendException('Gemini returned no text');
      }
      return result;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      throw ChatBackendException(
        status == null ? 'Gemini connection failed' : 'Gemini request failed ($status)',
        kind: status == 401 || status == 403
            ? ChatBackendErrorKind.auth
            : e.type == DioExceptionType.connectionTimeout ||
                    e.type == DioExceptionType.receiveTimeout ||
                    e.type == DioExceptionType.sendTimeout
                ? ChatBackendErrorKind.timeout
                : ChatBackendErrorKind.network,
      );
    }
  }
}
