import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

/// One element of an assistant turn — text, a tool call, or a thinking
/// block. The UI renders them in order so the user sees the actual
/// interleaving the model produced.
sealed class DisplayStep {
  Map<String, dynamic> toJson();
  static DisplayStep fromJson(Map<String, dynamic> json) {
    final t = json['type'] as String;
    switch (t) {
      case 'text':
        return TextStep(json['text'] as String);
      case 'thinking':
        return ThinkingStep(json['text'] as String);
      case 'tool_call':
        return ToolCallStep(
          id: json['id'] as String,
          name: json['name'] as String,
          input: (json['input'] as Map?)?.cast<String, dynamic>() ??
              const {},
          result: json['result'] as String?,
          isError: (json['is_error'] as bool?) ?? false,
        );
      default:
        return TextStep('');
    }
  }
}

class TextStep extends DisplayStep {
  String text;
  TextStep(this.text);
  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};
}

class ThinkingStep extends DisplayStep {
  String text;
  ThinkingStep(this.text);
  @override
  Map<String, dynamic> toJson() => {'type': 'thinking', 'text': text};
}

class ToolCallStep extends DisplayStep {
  final String id;
  final String name;
  Map<String, dynamic> input;
  String? result;
  bool isError;
  ToolCallStep({
    required this.id,
    required this.name,
    this.input = const {},
    this.result,
    this.isError = false,
  });
  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool_call',
        'id': id,
        'name': name,
        if (input.isNotEmpty) 'input': input,
        if (result != null) 'result': result,
        if (isError) 'is_error': true,
      };
}

/// A bubble shown in the chat UI — what the user sees. Assistant
/// messages are a list of [DisplayStep]s (text + tool_call + thinking,
/// in order). User messages are a single [TextStep].
class DisplayMessage {
  final String role; // 'user' | 'assistant'
  final List<DisplayStep> steps;
  final bool truncated;

  DisplayMessage({
    required this.role,
    required this.steps,
    this.truncated = false,
  });

  factory DisplayMessage.user(String text) => DisplayMessage(
        role: 'user',
        steps: [TextStep(text)],
      );

  /// Convenience: concatenated text across all [TextStep]s. Used for
  /// the history-list title preview, and as a fallback when older
  /// persisted messages don't have step granularity.
  String get text {
    return steps.whereType<TextStep>().map((s) => s.text).join('\n');
  }

  int get toolCallCount => steps.whereType<ToolCallStep>().length;

  Map<String, dynamic> toJson() => {
        'role': role,
        'steps': [for (final s in steps) s.toJson()],
        if (truncated) 'truncated': true,
      };

  factory DisplayMessage.fromJson(Map<String, dynamic> json) {
    // New format: { role, steps: [...] }
    if (json['steps'] is List) {
      return DisplayMessage(
        role: json['role'] as String,
        steps: [
          for (final s in json['steps'] as List)
            DisplayStep.fromJson((s as Map).cast<String, dynamic>()),
        ],
        truncated: (json['truncated'] as bool?) ?? false,
      );
    }
    // Legacy format: { role, text, tool_calls?, truncated? } —
    // historical sessions that pre-date steps. Collapse to one
    // TextStep so they still render.
    return DisplayMessage(
      role: json['role'] as String,
      steps: [TextStep((json['text'] as String?) ?? '')],
      truncated: (json['truncated'] as bool?) ?? false,
    );
  }
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
