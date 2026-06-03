import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/model_config.dart';
import '../models/view_schema.dart';
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
        "- read_screen_context: dump the view the user is looking at + "
            "recent rows. Call this when they ask about 'this view' / "
            "'my data'.",
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
      "For schema/template edits: fetch the current file first "
          "(read_repo_file), show the diff in plain English, wait for "
          "confirm before calling propose_change.",
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
              SelectableText(msg.text),
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
