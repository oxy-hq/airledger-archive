import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/model_config.dart';
import 'llm_client.dart';

/// One conversation turn — `role` is 'user' or 'assistant'. `content` is
/// either a plain string (simple user message) or a list of content
/// blocks (`{type, text}` / `{type, id, name, input}` / `{type,
/// tool_use_id, content}`). Mirrors Anthropic's messages API shape so we
/// don't add a translation layer on top.
class ChatTurn {
  final String role;
  final dynamic content;
  ChatTurn({required this.role, required this.content});

  Map<String, dynamic> toJson() => {'role': role, 'content': content};

  /// Convenience: extract all `text` blocks from this assistant turn,
  /// joined into a single string. Returns empty for tool-only turns.
  String get text {
    if (content is String) return content as String;
    if (content is List) {
      return (content as List)
          .whereType<Map>()
          .where((b) => b['type'] == 'text')
          .map((b) => b['text'] as String)
          .join('\n')
          .trim();
    }
    return '';
  }
}

/// One callable the LLM can invoke. The [run] function gets the validated
/// input map and returns a string (becomes the tool_result content).
/// Throwing yields an error tool_result so the LLM can self-correct.
class ChatTool {
  final String name;
  final String description;

  /// JSON schema describing the input shape. The Anthropic API uses this
  /// to coerce + validate before invoking.
  final Map<String, dynamic> inputSchema;

  final Future<String> Function(Map<String, dynamic> input) run;

  ChatTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.run,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'input_schema': inputSchema,
      };
}

class ChatResult {
  /// Final assistant text — the text blocks from the model's last reply.
  final String text;

  /// Full conversation including assistant + tool_result turns from the
  /// loop. The caller persists this to use as the input for the next user
  /// message.
  final List<ChatTurn> conversation;

  /// How many tool calls fired across the loop.
  final int toolCallCount;

  /// True if the loop hit [ChatRunner.maxIterations] without the model
  /// concluding. The text will be the last text block produced.
  final bool truncated;

  ChatResult({
    required this.text,
    required this.conversation,
    required this.toolCallCount,
    required this.truncated,
  });
}

/// Runs the Anthropic tool-use loop. Sends the conversation + tool defs,
/// executes any tool_use blocks via their registered [ChatTool.run],
/// feeds the results back as tool_result turns, repeats until the model
/// stops calling tools (or we hit a safety cap).
class ChatRunner {
  final ModelConfig model;
  final http.Client _http;
  final int maxIterations;

  ChatRunner(this.model, {http.Client? httpClient, this.maxIterations = 8})
      : _http = httpClient ?? http.Client(),
        assert(model.vendor == ModelVendor.anthropic,
            'ChatRunner currently only speaks Anthropic — chat models lookup '
            'should pick an anthropic-vendor entry from config.yml');

  Future<ChatResult> run({
    required String systemPrompt,
    required List<ChatTurn> conversation,
    required List<ChatTool> tools,
  }) async {
    final history = List<ChatTurn>.from(conversation);
    var toolCalls = 0;

    for (var iter = 0; iter < maxIterations; iter++) {
      final resp = await _call(systemPrompt, history, tools);
      final assistantBlocks = resp['content'] as List;
      history.add(ChatTurn(role: 'assistant', content: assistantBlocks));
      final stopReason = resp['stop_reason'];

      // No more tool calls — model has produced a final response.
      if (stopReason != 'tool_use') {
        return ChatResult(
          text: _joinText(assistantBlocks),
          conversation: history,
          toolCallCount: toolCalls,
          truncated: false,
        );
      }

      // Execute each tool_use block in this turn and feed results back as
      // a single user turn containing all tool_result blocks (Anthropic
      // requires the results to ride together if the assistant turn had
      // multiple tool_use blocks).
      final toolResults = <Map<String, dynamic>>[];
      for (final block in assistantBlocks) {
        if (block is! Map || block['type'] != 'tool_use') continue;
        toolCalls++;
        final id = block['id'] as String;
        final name = block['name'] as String;
        final input = (block['input'] as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        );
        final tool = tools.firstWhere(
          (t) => t.name == name,
          orElse: () => throw StateError(
            'Model called unknown tool "$name". Known: '
            '${tools.map((t) => t.name).join(", ")}',
          ),
        );
        try {
          final result = await tool.run(input);
          toolResults.add({
            'type': 'tool_result',
            'tool_use_id': id,
            'content': result,
          });
        } catch (e) {
          toolResults.add({
            'type': 'tool_result',
            'tool_use_id': id,
            'content': 'Error: $e',
            'is_error': true,
          });
        }
      }
      history.add(ChatTurn(role: 'user', content: toolResults));
    }

    // Loop bailed out — return what we have. Last assistant turn's text
    // is the best we can show.
    final lastAssistant = history.lastWhere(
      (t) => t.role == 'assistant',
      orElse: () => ChatTurn(role: 'assistant', content: const []),
    );
    return ChatResult(
      text: lastAssistant.text,
      conversation: history,
      toolCallCount: toolCalls,
      truncated: true,
    );
  }

  Future<Map<String, dynamic>> _call(
    String systemPrompt,
    List<ChatTurn> history,
    List<ChatTool> tools,
  ) async {
    final body = <String, dynamic>{
      'model': model.modelRef,
      'max_tokens': 2048,
      'system': systemPrompt,
      'messages': history.map((t) => t.toJson()).toList(),
      if (tools.isNotEmpty)
        'tools': tools.map((t) => t.toJson()).toList(),
    };
    final resp = await _http.post(
      Uri.parse('${model.apiUrl}/messages'),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': model.apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw LlmCallException(
        vendor: 'Anthropic',
        status: resp.statusCode,
        body: resp.body,
      );
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  String _joinText(List blocks) {
    return blocks
        .whereType<Map>()
        .where((b) => b['type'] == 'text')
        .map((b) => (b['text'] as String).trim())
        .where((s) => s.isNotEmpty)
        .join('\n');
  }
}
