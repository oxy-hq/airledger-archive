import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

/// A bubble shown in the chat UI — what the user sees, separate from the
/// raw conversation turns sent to the LLM. Tool-result + tool-use turns
/// (which fly between the model and the chat-runner) don't appear here;
/// the UI shows user text + assistant text only, plus a small
/// "N tool calls" caption when the assistant invoked anything.
class DisplayMessage {
  final String role; // 'user' | 'assistant'
  final String text;
  final int toolCalls;
  final bool truncated;

  DisplayMessage({
    required this.role,
    required this.text,
    this.toolCalls = 0,
    this.truncated = false,
  });

  factory DisplayMessage.user(String text) =>
      DisplayMessage(role: 'user', text: text);

  factory DisplayMessage.assistant(
    String text, {
    int toolCalls = 0,
    bool truncated = false,
  }) =>
      DisplayMessage(
        role: 'assistant',
        text: text,
        toolCalls: toolCalls,
        truncated: truncated,
      );

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
        if (toolCalls > 0) 'tool_calls': toolCalls,
        if (truncated) 'truncated': true,
      };

  factory DisplayMessage.fromJson(Map<String, dynamic> json) => DisplayMessage(
        role: json['role'] as String,
        text: json['text'] as String,
        toolCalls: (json['tool_calls'] as int?) ?? 0,
        truncated: (json['truncated'] as bool?) ?? false,
      );
}

/// One persisted chat — what the history screen lists and what
/// ChatScreen restores when the user taps a past conversation.
///
/// Persists BOTH:
///   - `turns`   — full LLM conversation (Anthropic content blocks),
///                needed to resume so the model has its prior context
///   - `displayed` — the UI-side messages, used to re-render the bubbles
///                   without replaying the tool-use loop
///
/// View attribution lives on the session (not per-message) — a chat is
/// scoped to one view's context (or to no view if launched from
/// HomeScreen).
class ChatSession {
  final String id;
  final String? viewName;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<Map<String, dynamic>> turns;
  final List<DisplayMessage> displayed;

  ChatSession({
    required this.id,
    required this.viewName,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.turns,
    required this.displayed,
  });

  /// Fresh session with a generated id and timestamps.
  factory ChatSession.fresh({String? viewName}) {
    final now = DateTime.now();
    return ChatSession(
      id: const Uuid().v4(),
      viewName: viewName,
      title: 'New chat',
      createdAt: now,
      updatedAt: now,
      turns: [],
      displayed: [],
    );
  }

  ChatSession copyWith({
    String? title,
    DateTime? updatedAt,
    List<Map<String, dynamic>>? turns,
    List<DisplayMessage>? displayed,
  }) =>
      ChatSession(
        id: id,
        viewName: viewName,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        turns: turns ?? this.turns,
        displayed: displayed ?? this.displayed,
      );

  /// Short preview for the history list — first ~80 chars of the title.
  String get titlePreview {
    final t = title.trim();
    if (t.length <= 80) return t;
    return '${t.substring(0, 77)}…';
  }

  /// Human label for the history list — "today", "yesterday", or short
  /// date. Uses [updatedAt] since that's what changes during use.
  String get updatedAtLabel {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final updatedDay =
        DateTime(updatedAt.year, updatedAt.month, updatedAt.day);
    if (updatedDay == today) {
      return DateFormat('jm').format(updatedAt);
    }
    if (updatedDay == yesterday) return 'Yesterday';
    if (now.difference(updatedAt).inDays < 7) {
      return DateFormat('EEEE').format(updatedAt);
    }
    return DateFormat('MMM d').format(updatedAt);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        if (viewName != null) 'view': viewName,
        'title': title,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'turns': turns,
        'displayed': displayed.map((d) => d.toJson()).toList(),
      };

  factory ChatSession.fromJson(Map<String, dynamic> json) => ChatSession(
        id: json['id'] as String,
        viewName: json['view'] as String?,
        title: json['title'] as String? ?? 'Untitled',
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
        turns: ((json['turns'] as List?) ?? const [])
            .map((t) => (t as Map).cast<String, dynamic>())
            .toList(),
        displayed: ((json['displayed'] as List?) ?? const [])
            .map((d) => DisplayMessage.fromJson(
                  (d as Map).cast<String, dynamic>(),
                ))
            .toList(),
      );
}
