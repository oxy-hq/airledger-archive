import 'dart:async';
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

// --- Stream events --------------------------------------------------------

/// Events yielded by [ChatRunner.runStream] as the conversation progresses.
/// Each one corresponds to something the UI can render: a token chunk, a
/// tool starting/finishing, the model reasoning out loud, etc.
sealed class ChatStreamEvent {}

/// Incremental text from the model (a token or small group of tokens).
/// The UI appends to the current text block.
class TextDelta extends ChatStreamEvent {
  final String chunk;
  TextDelta(this.chunk);
}

/// Incremental reasoning from the model (extended-thinking blocks).
class ThinkingDelta extends ChatStreamEvent {
  final String chunk;
  ThinkingDelta(this.chunk);
}

/// Model decided to call a tool. The full input may still be streaming
/// in; UI typically renders a card with name + "running" spinner.
class ToolUseStart extends ChatStreamEvent {
  final String id;
  final String name;
  ToolUseStart({required this.id, required this.name});
}

/// Tool input is fully parsed and the dart-side handler is about to fire.
class ToolUseExecuting extends ChatStreamEvent {
  final String id;
  final String name;
  final Map<String, dynamic> input;
  ToolUseExecuting({
    required this.id,
    required this.name,
    required this.input,
  });
}

/// Tool finished. `isError` distinguishes a thrown exception from a
/// normal return (the LLM sees both, so it can self-correct).
class ToolUseResult extends ChatStreamEvent {
  final String id;
  final String result;
  final bool isError;
  ToolUseResult({
    required this.id,
    required this.result,
    required this.isError,
  });
}

/// A content block finished. UI uses this to flush any accumulated state
/// (e.g. seal the current text bubble before the next block opens).
class BlockEnded extends ChatStreamEvent {
  /// `text`, `tool_use`, or `thinking`.
  final String blockType;
  BlockEnded(this.blockType);
}

/// The whole conversation step is done — either because the model
/// produced a final answer (no more tool calls) or we hit the safety
/// cap on iterations.
class TurnComplete extends ChatStreamEvent {
  final bool truncated;

  /// Full updated conversation history (including tool_use / tool_result
  /// turns from the loop). Caller persists this for resume.
  final List<ChatTurn> conversation;

  final int toolCallCount;

  TurnComplete({
    required this.truncated,
    required this.conversation,
    required this.toolCallCount,
  });
}

// --- Runner --------------------------------------------------------------

/// Streams an Anthropic chat completion + drives the tool-use loop.
/// Each call to [runStream] is one user message → potentially many
/// assistant turns separated by tool executions.
class ChatRunner {
  final ModelConfig model;
  final http.Client _http;
  final int maxIterations;

  /// When true, requests extended thinking. Adds a few seconds of
  /// reasoning before the response but produces ThinkingDelta events
  /// the UI can surface. Sonnet 4.x supports it; older models return
  /// 400.
  final bool enableThinking;
  final int thinkingBudgetTokens;

  ChatRunner(
    this.model, {
    http.Client? httpClient,
    this.maxIterations = 8,
    this.enableThinking = false,
    this.thinkingBudgetTokens = 3000,
  })  : _http = httpClient ?? http.Client(),
        assert(model.vendor == ModelVendor.anthropic,
            'ChatRunner currently only speaks Anthropic.');

  Stream<ChatStreamEvent> runStream({
    required String systemPrompt,
    required List<ChatTurn> initialConversation,
    required List<ChatTool> tools,
  }) async* {
    final history = List<ChatTurn>.from(initialConversation);
    var toolCalls = 0;

    for (var iter = 0; iter < maxIterations; iter++) {
      // Collect content blocks as they stream in. Keyed by SSE `index`
      // because blocks can interleave (though Anthropic typically sends
      // them in order).
      final blocks = <int, Map<String, dynamic>>{};
      final toolInputBuffers = <int, StringBuffer>{};
      String? stopReason;

      await for (final ev in _streamMessages(systemPrompt, history, tools)) {
        final type = ev['type'];
        if (type == 'content_block_start') {
          final index = ev['index'] as int;
          final block =
              Map<String, dynamic>.from(ev['content_block'] as Map);
          blocks[index] = block;
          final blockType = block['type'];
          if (blockType == 'tool_use') {
            toolInputBuffers[index] = StringBuffer();
            yield ToolUseStart(
              id: block['id'] as String,
              name: block['name'] as String,
            );
          }
          // text + thinking blocks open silently — the delta events
          // surface their content.
        } else if (type == 'content_block_delta') {
          final index = ev['index'] as int;
          final delta = ev['delta'] as Map;
          final dType = delta['type'];
          final blk = blocks[index];
          if (blk == null) continue;
          if (dType == 'text_delta') {
            final chunk = delta['text'] as String;
            blk['text'] = ((blk['text'] as String?) ?? '') + chunk;
            yield TextDelta(chunk);
          } else if (dType == 'input_json_delta') {
            toolInputBuffers[index]?.write(delta['partial_json'] ?? '');
          } else if (dType == 'thinking_delta') {
            final chunk = delta['thinking'] as String;
            blk['thinking'] = ((blk['thinking'] as String?) ?? '') + chunk;
            yield ThinkingDelta(chunk);
          } else if (dType == 'signature_delta') {
            // Extended-thinking signature payload — store, don't render.
            blk['signature'] =
                ((blk['signature'] as String?) ?? '') +
                    (delta['signature'] as String? ?? '');
          }
        } else if (type == 'content_block_stop') {
          final index = ev['index'] as int;
          final blk = blocks[index];
          if (blk == null) continue;
          if (blk['type'] == 'tool_use') {
            final jsonStr = toolInputBuffers[index]?.toString() ?? '';
            try {
              blk['input'] =
                  jsonStr.isEmpty ? <String, dynamic>{} : jsonDecode(jsonStr);
            } catch (_) {
              blk['input'] = <String, dynamic>{};
            }
          }
          yield BlockEnded(blk['type'] as String);
        } else if (type == 'message_delta') {
          final delta = ev['delta'] as Map;
          if (delta['stop_reason'] != null) {
            stopReason = delta['stop_reason'] as String;
          }
        }
        // message_start / message_stop / ping aren't interesting here.
      }

      // Assemble the assistant turn in index order.
      final sortedIndices = blocks.keys.toList()..sort();
      final assistantBlocks = [for (final i in sortedIndices) blocks[i]!];
      history.add(ChatTurn(role: 'assistant', content: assistantBlocks));

      if (stopReason != 'tool_use') {
        yield TurnComplete(
          truncated: false,
          conversation: history,
          toolCallCount: toolCalls,
        );
        return;
      }

      // Execute tool_use blocks; feed results back as a single user turn.
      final toolResults = <Map<String, dynamic>>[];
      for (final block in assistantBlocks) {
        if (block['type'] != 'tool_use') continue;
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
        yield ToolUseExecuting(id: id, name: name, input: input);
        try {
          final result = await tool.run(input);
          toolResults.add({
            'type': 'tool_result',
            'tool_use_id': id,
            'content': result,
          });
          yield ToolUseResult(id: id, result: result, isError: false);
        } catch (e) {
          toolResults.add({
            'type': 'tool_result',
            'tool_use_id': id,
            'content': 'Error: $e',
            'is_error': true,
          });
          yield ToolUseResult(id: id, result: 'Error: $e', isError: true);
        }
      }
      history.add(ChatTurn(role: 'user', content: toolResults));
    }

    yield TurnComplete(
      truncated: true,
      conversation: history,
      toolCallCount: toolCalls,
    );
  }

  Stream<Map<String, dynamic>> _streamMessages(
    String systemPrompt,
    List<ChatTurn> history,
    List<ChatTool> tools,
  ) async* {
    final body = <String, dynamic>{
      'model': model.modelRef,
      'max_tokens': 4096,
      'system': systemPrompt,
      'messages': history.map((t) => t.toJson()).toList(),
      if (tools.isNotEmpty) 'tools': tools.map((t) => t.toJson()).toList(),
      'stream': true,
      if (enableThinking)
        'thinking': {
          'type': 'enabled',
          'budget_tokens': thinkingBudgetTokens,
        },
    };
    final req = http.Request(
      'POST',
      Uri.parse('${model.apiUrl}/messages'),
    );
    req.headers.addAll({
      'Content-Type': 'application/json',
      'x-api-key': model.apiKey,
      'anthropic-version': '2023-06-01',
    });
    req.body = jsonEncode(body);
    final streamed = await _http.send(req);
    if (streamed.statusCode != 200) {
      final errBody = await streamed.stream.bytesToString();
      throw LlmCallException(
        vendor: 'Anthropic',
        status: streamed.statusCode,
        body: errBody,
      );
    }

    final lines = streamed.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data: ')) continue;
      final raw = line.substring(6);
      if (raw == '[DONE]') return;
      try {
        yield jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        // Skip lines that aren't JSON (shouldn't happen with Anthropic).
      }
    }
  }
}
