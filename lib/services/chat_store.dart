import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_session.dart';

/// Per-session local store for chat history. Backed by `shared_preferences`
/// — small (a few hundred KB at most) and synchronous-ish to load.
///
/// Layout:
///   `chat:index` → JSON list of `{id, view, title, updated_at}` summaries,
///                  newest-first. Drives the history screen without
///                  forcing us to read every full session blob.
///   `chat:<id>`  → JSON of the full ChatSession (turns + displayed).
///
/// Capped at [_maxSessions] entries. When the cap is exceeded, the oldest
/// sessions are deleted (their `chat:<id>` blob + their index entry).
class ChatStore {
  static const _indexKey = 'chat:index';
  static const _sessionPrefix = 'chat:';
  static const _maxSessions = 50;

  /// All session summaries, newest-first. Cheap — only loads the index.
  static Future<List<ChatSessionSummary>> listAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_indexKey);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final entry in list)
          ChatSessionSummary.fromJson(
            (entry as Map).cast<String, dynamic>(),
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Load a full session by id. Null if missing.
  static Future<ChatSession?> load(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_sessionPrefix$id');
    if (raw == null) return null;
    try {
      return ChatSession.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Persists [session] — writes both the full blob and updates the index
  /// (moves the id to the top, since updatedAt just changed). Prunes the
  /// oldest sessions if we're over [_maxSessions].
  static Future<void> save(ChatSession session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_sessionPrefix${session.id}',
      jsonEncode(session.toJson()),
    );
    final all = await listAll();
    // Drop any existing entry for this id, prepend the fresh summary.
    final updated = [
      ChatSessionSummary.fromSession(session),
      ...all.where((s) => s.id != session.id),
    ];
    // Prune past the cap (oldest first).
    final pruned = updated.length <= _maxSessions
        ? updated
        : updated.sublist(0, _maxSessions);
    final removed = updated.length > _maxSessions
        ? updated.sublist(_maxSessions)
        : const <ChatSessionSummary>[];
    for (final r in removed) {
      await prefs.remove('$_sessionPrefix${r.id}');
    }
    await prefs.setString(
      _indexKey,
      jsonEncode([for (final s in pruned) s.toJson()]),
    );
  }

  static Future<void> delete(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_sessionPrefix$id');
    final all = await listAll();
    final filtered = all.where((s) => s.id != id).toList();
    await prefs.setString(
      _indexKey,
      jsonEncode([for (final s in filtered) s.toJson()]),
    );
  }

  /// Wipe all chat history — useful for debugging or a "clear all" UX.
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final all = await listAll();
    for (final s in all) {
      await prefs.remove('$_sessionPrefix${s.id}');
    }
    await prefs.remove(_indexKey);
  }
}

/// Light-weight row used by the history list — no turns, just metadata.
class ChatSessionSummary {
  final String id;
  final String? viewName;
  final String title;
  final DateTime updatedAt;

  ChatSessionSummary({
    required this.id,
    required this.viewName,
    required this.title,
    required this.updatedAt,
  });

  factory ChatSessionSummary.fromSession(ChatSession s) => ChatSessionSummary(
        id: s.id,
        viewName: s.viewName,
        title: s.title,
        updatedAt: s.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (viewName != null) 'view': viewName,
        'title': title,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory ChatSessionSummary.fromJson(Map<String, dynamic> json) =>
      ChatSessionSummary(
        id: json['id'] as String,
        viewName: json['view'] as String?,
        title: json['title'] as String? ?? 'Untitled',
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );

  /// Same label rule as ChatSession.updatedAtLabel — duplicated here so
  /// the history screen doesn't need to load the full session to label
  /// rows.
  String get updatedAtLabel {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final updatedDay =
        DateTime(updatedAt.year, updatedAt.month, updatedAt.day);
    if (updatedDay == today) {
      // jm = "9:41 AM" — kept simple to avoid an intl import in the model.
      final h = updatedAt.hour > 12 ? updatedAt.hour - 12 : updatedAt.hour;
      final hh = h == 0 ? 12 : h;
      final mm = updatedAt.minute.toString().padLeft(2, '0');
      final ap = updatedAt.hour >= 12 ? 'PM' : 'AM';
      return '$hh:$mm $ap';
    }
    if (updatedDay == yesterday) return 'Yesterday';
    final daysAgo = now.difference(updatedAt).inDays;
    if (daysAgo < 7) {
      const wkd = [
        'Mon',
        'Tue',
        'Wed',
        'Thu',
        'Fri',
        'Sat',
        'Sun',
      ];
      return wkd[updatedAt.weekday - 1];
    }
    const mo = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${mo[updatedAt.month - 1]} ${updatedAt.day}';
  }
}
