import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:intl/intl.dart';

import '../models/chat_session.dart';
import '../models/model_config.dart';
import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/chat_runner.dart';
import '../services/chat_store.dart';
import '../services/chat_tools.dart';
import '../services/github_client.dart';
import '../services/llm_client.dart';
import '../services/sheets_repository.dart';
import 'chat_history_screen.dart';

/// In-app AI assistant. Tool-using LLM that can read the current screen's
/// view context, browse the schemas repo, and open PRs against it.
///
/// State is per-session — closing the screen drops the conversation.
/// Persistence can come later if useful; the LLM works fine without it.
class ChatScreen extends StatefulWidget {
  final ModelConfig model;
  final GithubClient? github;

  /// When opened from a TimelineScreen, the view + repo are passed so
  /// the read_screen_context tool can answer questions about "this
  /// view" without the user having to describe it.
  final ViewSchema? view;
  final SheetsRepository? repository;

  /// Airlayer + LocalDb. Enables the chat's run_query tool for ad-hoc
  /// aggregates over history (max squat, total volume last week, etc).
  /// Optional — chat opens fine without it, just no run_query.
  final AnalyticsEngine? analytics;

  /// The date the user has selected on the timeline. apply_template
  /// defaults its target date to this when the user doesn't specify
  /// otherwise (so "apply cut_squat_heavy" plans for the day they're
  /// looking at). Null when chat is opened from a non-date context.
  final DateTime? selectedDate;

  /// Optional persisted session to restore. When set, the screen opens
  /// with the full conversation visible and the LLM's prior context
  /// intact; sending a new message picks up the conversation.
  final ChatSession? resume;

  const ChatScreen({
    super.key,
    required this.model,
    this.github,
    this.view,
    this.repository,
    this.analytics,
    this.selectedDate,
    this.resume,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  late final List<DisplayMessage> _displayed;
  late final List<ChatTurn> _history;
  late ChatSession _session;
  bool _sending = false;
  bool _compacting = false;
  String? _error;

  /// Compaction trigger: when the LLM conversation exceeds this many
  /// turns (Anthropic content blocks count, including tool_result turns
  /// the chat runner inserts), we summarize the older portion via a
  /// non-tool LLM call. Keeps the tail intact so the model still has
  /// recent precise context.
  static const _compactTriggerTurns = 30;
  static const _compactKeepRecent = 6;

  late final ChatToolset _toolset = ChatToolset(
    github: widget.github,
    view: widget.view,
    repository: widget.repository,
    analytics: widget.analytics,
    selectedDate: widget.selectedDate,
  );

  late final ChatRunner _runner = ChatRunner(widget.model);

  String get _systemPrompt {
    final lines = <String>[
      "You are Airledger's in-app assistant. Be concise — short answers, "
          "no preamble.",
      "",
      "Capabilities you have via tools:",
      if (widget.view != null) ...[
        "- read_screen_context: dump the view's schema (dimensions, "
            "measures) + 20 most recent rows. Call FIRST when the user "
            "asks about 'this view' / 'my data' — it tells you which "
            "measure/dim names you can query.",
        if (widget.analytics != null)
          "- run_query: aggregate query against full history via "
              "airlayer. Use for 'max squat', 'total volume last week', "
              "'sets per exercise last month' — anything that needs to "
              "look at more than the 20 recent rows. Shape: "
              "{measures, dimensions?, filters?, order?, limit?}.",
        "- list_templates / read_template: discover what plans are "
            "available for this view, with their variable specs.",
        "- apply_template: create planned (not-yet-logged) entries on "
            "a target date. Only call this AFTER the user agrees to a "
            "specific template + variable values you've shown them.",
        "- add_planned_entry: create a single planned row. Use for "
            "ad-hoc additions outside a template. Same confirm rule "
            "as apply_template.",
        "- log_entry: write directly to the sheet, skipping the "
            "planned step. ONLY when the user explicitly says 'log' "
            "(vs. 'plan' / 'add').",
      ],
      if (widget.github != null) ...[
        "- list_repo_dir / read_repo_file: browse the schemas repo.",
        "- propose_change: open a PR with a single-file update. Only call "
            "this AFTER the user agrees to a specific change you've "
            "shown them. Never propose silently.",
      ],
      "",
      "For 'what should I do today' style questions: call list_templates "
          "to see what's available, read_screen_context to see what "
          "they've done recently, then SUGGEST a template + reasoned "
          "variable values. Wait for confirm before applying.",
      "",
      "For 'what's my max X' or 'how much volume last week' style "
          "questions: use run_query — read_screen_context's recent "
          "rows only show 20, run_query goes against all history.",
      "",
      "For schema/template edits: fetch the current file first "
          "(read_repo_file), show the diff in plain English, wait for "
          "confirm before calling propose_change.",
      "",
      "Format responses as Markdown. Use **bold** for emphasis on "
          "numbers and exercise names, bullet lists for sets/options, "
          "and `code spans` for field names and template names. Keep "
          "it scannable — short bullets > prose for any list of facts.",
      "",
      "When a tool errors, show the raw error message verbatim in a "
          "code block so the user can debug. Don't soften it to 'I'm "
          "having trouble' — that hides what actually broke.",
    ];
    if (widget.view != null) {
      lines.addAll([
        "",
        "Currently open view: ${widget.view!.name}"
            "${widget.view!.description != null ? " (${widget.view!.description})" : ""}",
      ]);
    }
    if (widget.selectedDate != null) {
      lines.add(
        "Currently-viewed date: "
        "${DateFormat('yyyy-MM-dd (EEEE)').format(widget.selectedDate!)}",
      );
    }
    return lines.join('\n');
  }

  @override
  void initState() {
    super.initState();
    final resume = widget.resume;
    if (resume != null) {
      _session = resume;
      _displayed = List<DisplayMessage>.from(resume.displayed);
      _history = [
        for (final raw in resume.turns)
          ChatTurn(
            role: raw['role'] as String,
            content: raw['content'],
          ),
      ];
    } else {
      _session = ChatSession.fresh(viewName: widget.view?.name);
      _displayed = [];
      _history = [];
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

    // Compact the conversation if it's grown past the trigger. The first
    // user message of the session also becomes the title; do this before
    // mutating state so the title sticks even if the LLM call fails.
    if (_session.title == 'New chat') {
      _session = _session.copyWith(title: _truncateTitle(text));
    }

    setState(() {
      _displayed.add(DisplayMessage.user(text));
      _history.add(ChatTurn(role: 'user', content: text));
      _controller.clear();
      _sending = true;
      _error = null;
    });
    _scrollToBottom();

    try {
      if (_history.length > _compactTriggerTurns) {
        setState(() => _compacting = true);
        final compacted = await _compactHistory(_history);
        if (!mounted) return;
        _history
          ..clear()
          ..addAll(compacted);
        setState(() => _compacting = false);
      }

      final result = await _runner.run(
        systemPrompt: _systemPrompt,
        conversation: _history,
        tools: _toolset.build(),
      );
      if (!mounted) return;
      setState(() {
        _history
          ..clear()
          ..addAll(result.conversation);
        _displayed.add(DisplayMessage.assistant(
          result.text.isEmpty ? '(no response)' : result.text,
          toolCalls: result.toolCallCount,
          truncated: result.truncated,
        ));
        _sending = false;
      });
      _scrollToBottom();
      await _persist();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _sending = false;
        _compacting = false;
      });
    }
  }

  /// Snapshot the current state into _session and save to disk. Best-
  /// effort: a failure here doesn't block the chat.
  Future<void> _persist() async {
    _session = _session.copyWith(
      updatedAt: DateTime.now(),
      turns: [for (final t in _history) t.toJson()],
      displayed: List<DisplayMessage>.from(_displayed),
    );
    try {
      await ChatStore.save(_session);
    } catch (_) {
      // Persistence failure should not surface to the user — they can
      // still chat; just won't see this session in history.
    }
  }

  /// Ask a fresh LLM call (no tools) to summarize the older portion of
  /// the conversation. Replaces those turns with one synthetic user
  /// turn so the model retains the gist without paying for the full
  /// token cost on every subsequent message.
  Future<List<ChatTurn>> _compactHistory(List<ChatTurn> turns) async {
    final tail = turns.sublist(turns.length - _compactKeepRecent);
    final head = turns.sublist(0, turns.length - _compactKeepRecent);
    final transcript = head
        .map((t) {
          if (t.content is String) return '${t.role}: ${t.content}';
          // For content-block turns (tool_use / tool_result), just join
          // any text blocks. Tool calls add noise but no info the
          // summary needs to preserve verbatim.
          if (t.content is List) {
            final texts = (t.content as List)
                .whereType<Map>()
                .where((b) => b['type'] == 'text')
                .map((b) => b['text'] as String)
                .join(' ');
            return '${t.role}: $texts';
          }
          return '';
        })
        .where((s) => s.trim().isNotEmpty)
        .join('\n');
    final prompt =
        'Summarize this earlier portion of a conversation in 3-5 sentences. '
        'Preserve concrete decisions, values, and facts that were discussed. '
        'Do not editorialize.\n\n[CONVERSATION]\n$transcript';
    final summary = await LlmClient([widget.model]).complete(
      widget.model.name,
      prompt,
    );
    return [
      ChatTurn(
        role: 'user',
        content:
            '(Earlier in this conversation, summarized:)\n${summary.trim()}',
      ),
      ...tail,
    ];
  }

  String _truncateTitle(String s) {
    final cleaned = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= 60) return cleaned;
    return '${cleaned.substring(0, 57)}…';
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.view == null
        ? 'Chat'
        : 'Chat · ${widget.view!.name}';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Chat history',
            onPressed: () async {
              // Save the current state first so it shows up in history.
              if (_displayed.isNotEmpty) await _persist();
              if (!mounted) return;
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChatHistoryScreen(
                    model: widget.model,
                    github: widget.github?.config,
                    repository: widget.repository,
                    analytics: widget.analytics,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _displayed.isEmpty
                ? _EmptyHint(viewName: widget.view?.name)
                : ListView.separated(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _displayed.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _MsgBubble(msg: _displayed[i]),
                  ),
          ),
          if (_compacting)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.secondaryContainer,
              padding: const EdgeInsets.all(8),
              child: Text(
                'Compacting earlier conversation…',
                style: TextStyle(
                  color:
                      Theme.of(context).colorScheme.onSecondaryContainer,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          if (_error != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.all(8),
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          SafeArea(
            top: false,
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 4,
                      enabled: !_sending,
                      decoration: const InputDecoration(
                        hintText: 'Ask anything…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.send),
                    onPressed: _sending ? null : _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MsgBubble extends StatelessWidget {
  final DisplayMessage msg;
  const _MsgBubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = msg.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color:
                isUser ? scheme.primaryContainer : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // User messages stay plain text (no markdown parsing on
              // user input — what they type is what they meant).
              // Assistant messages get rendered as Markdown so bullets,
              // bold, headers, and code spans display properly.
              if (isUser)
                SelectableText(msg.text)
              else
                MarkdownBody(
                  data: msg.text,
                  selectable: true,
                  styleSheet: MarkdownStyleSheet.fromTheme(
                    Theme.of(context),
                  ).copyWith(
                    p: Theme.of(context).textTheme.bodyMedium,
                    code: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          backgroundColor: scheme.surfaceContainerHighest,
                        ),
                    codeblockDecoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    // Blockquote — explicit colors instead of theme
                    // defaults, which were picking up primaryContainer
                    // (light blue) for both bg and text and rendering
                    // unreadably on light themes.
                    blockquote:
                        Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurface,
                              fontStyle: FontStyle.italic,
                            ),
                    blockquoteDecoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                      border: Border(
                        left: BorderSide(color: scheme.primary, width: 3),
                      ),
                    ),
                    blockquotePadding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                  ),
                ),
              if (msg.toolCalls > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    msg.truncated
                        ? '${msg.toolCalls} tool call(s) · loop truncated'
                        : '${msg.toolCalls} tool call(s)',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String? viewName;
  const _EmptyHint({this.viewName});
  @override
  Widget build(BuildContext context) {
    final lines = [
      if (viewName != null)
        'Ask about $viewName — "what was my last set?", "add hollow body '
            'hold to the isometric group".'
      else
        'Ask about your data or your schemas. I can browse the repo and '
            'open PRs.',
    ];
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          lines.join('\n\n'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}
