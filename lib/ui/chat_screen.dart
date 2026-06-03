import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:intl/intl.dart';

import '../models/model_config.dart';
import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/chat_runner.dart';
import '../services/chat_tools.dart';
import '../services/github_client.dart';
import '../services/sheets_repository.dart';

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

  const ChatScreen({
    super.key,
    required this.model,
    this.github,
    this.view,
    this.repository,
    this.analytics,
    this.selectedDate,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final List<_DisplayMsg> _displayed = [];
  final List<ChatTurn> _history = [];
  bool _sending = false;
  String? _error;

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
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _displayed.add(_DisplayMsg.user(text));
      _history.add(ChatTurn(role: 'user', content: text));
      _controller.clear();
      _sending = true;
      _error = null;
    });
    _scrollToBottom();

    try {
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
        _displayed.add(_DisplayMsg.assistant(
          result.text.isEmpty ? '(no response)' : result.text,
          toolCalls: result.toolCallCount,
          truncated: result.truncated,
        ));
        _sending = false;
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _sending = false;
      });
    }
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
      appBar: AppBar(title: Text(title)),
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

class _DisplayMsg {
  final String role; // 'user' | 'assistant'
  final String text;
  final int toolCalls;
  final bool truncated;
  _DisplayMsg({
    required this.role,
    required this.text,
    this.toolCalls = 0,
    this.truncated = false,
  });
  factory _DisplayMsg.user(String text) =>
      _DisplayMsg(role: 'user', text: text);
  factory _DisplayMsg.assistant(
    String text, {
    int toolCalls = 0,
    bool truncated = false,
  }) =>
      _DisplayMsg(
        role: 'assistant',
        text: text,
        toolCalls: toolCalls,
        truncated: truncated,
      );
}

class _MsgBubble extends StatelessWidget {
  final _DisplayMsg msg;
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
