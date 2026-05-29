// ignore_for_file: avoid_print
//
// One-shot migration: splits each `<name>.view.yml` in a directory into
// two paired files:
//
//   <name>.view.yml   — semantic layer (name, datasource, table,
//                       entities, dimensions w/ name/type/expr/description,
//                       measures)
//   <name>.input.yml  — input layer (date_field, plannable, list_display,
//                       spreadsheet_id, per-dimension input/samples/
//                       show_when/derive)
//
// Run on every directory that holds ledger view files. Backs up the
// original by writing `.view.yml.bak` unless `--no-backup`.
//
// Usage:
//   dart run tool/split_views.dart <dir> [--no-backup]
//
// The script uses YAML output that is functional but not byte-exact —
// comments and original ordering are lost. Re-format/reorder by hand if
// you care.

import 'dart:io';

import 'package:yaml/yaml.dart';

const _viewLevelInputFields = {
  'date_field',
  'plannable',
  'list_display',
  'spreadsheet_id',
};
const _dimensionInputFields = {
  'input',
  'samples',
  'show_when',
  'derive',
};

Future<int> main(List<String> argv) async {
  if (argv.isEmpty || argv.contains('-h') || argv.contains('--help')) {
    print('Usage: dart run tool/split_views.dart <dir> [--no-backup]');
    return argv.isEmpty ? 1 : 0;
  }
  final dir = Directory(argv.first);
  if (!dir.existsSync()) {
    print('error: directory not found: ${dir.path}');
    return 1;
  }
  final noBackup = argv.contains('--no-backup');

  final viewFiles = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.view.yml'))
      .toList();
  if (viewFiles.isEmpty) {
    print('No .view.yml files in ${dir.path}');
    return 0;
  }

  for (final viewFile in viewFiles) {
    if (viewFile.path.endsWith('.bak.view.yml')) continue;
    final inputPath =
        viewFile.path.replaceAll(RegExp(r'\.view\.yml$'), '.input.yml');
    final inputFile = File(inputPath);

    final originalYaml = viewFile.readAsStringSync();
    final node = loadYaml(originalYaml);
    if (node is! YamlMap) {
      print('skip ${viewFile.path}: top-level is not a map');
      continue;
    }

    final viewName = node['name'];
    if (viewName is! String) {
      print('skip ${viewFile.path}: missing name:');
      continue;
    }

    final cleanView = <String, dynamic>{};
    final inputOverlay = <String, dynamic>{'view': viewName};

    for (final entry in node.entries) {
      final key = entry.key.toString();
      final value = entry.value;
      if (_viewLevelInputFields.contains(key)) {
        inputOverlay[key] = _toJson(value);
      } else if (key == 'dimensions' && value is YamlList) {
        // Split dimensions: keep semantic fields in view, peel input fields
        // into the overlay keyed by dimension name.
        final cleanDims = <dynamic>[];
        final overlayDims = <String, dynamic>{};
        for (final dim in value) {
          if (dim is! YamlMap) {
            cleanDims.add(_toJson(dim));
            continue;
          }
          final cleanDim = <String, dynamic>{};
          final overlayDim = <String, dynamic>{};
          for (final dEntry in dim.entries) {
            final dKey = dEntry.key.toString();
            if (_dimensionInputFields.contains(dKey)) {
              overlayDim[dKey] = _toJson(dEntry.value);
            } else {
              cleanDim[dKey] = _toJson(dEntry.value);
            }
          }
          cleanDims.add(cleanDim);
          final dimName = cleanDim['name'];
          if (overlayDim.isNotEmpty && dimName is String) {
            overlayDims[dimName] = overlayDim;
          }
        }
        cleanView['dimensions'] = cleanDims;
        if (overlayDims.isNotEmpty) {
          inputOverlay['dimensions'] = overlayDims;
        }
      } else {
        cleanView[key] = _toJson(value);
      }
    }

    if (!noBackup) {
      File('${viewFile.path}.bak').writeAsStringSync(originalYaml);
    }
    viewFile.writeAsStringSync(_emitYaml(cleanView));

    // Only emit .input.yml if there's anything beyond the back-pointer.
    final hasOverlay = inputOverlay.keys.where((k) => k != 'view').isNotEmpty;
    if (hasOverlay) {
      inputFile.writeAsStringSync(_emitYaml(inputOverlay));
    }

    print('split ${viewFile.path}'
        '${hasOverlay ? "  +  ${inputFile.path}" : "  (no input overlay)"}');
  }
  return 0;
}

/// Recursively converts YamlMap / YamlList to plain Dart maps and lists
/// so they can be re-emitted cleanly.
dynamic _toJson(dynamic v) {
  if (v is YamlMap) {
    return <String, dynamic>{
      for (final entry in v.entries) entry.key.toString(): _toJson(entry.value),
    };
  }
  if (v is YamlList) {
    return v.map(_toJson).toList();
  }
  return v;
}

String _emitYaml(dynamic node, [int depth = 0]) {
  final indent = '  ' * depth;
  if (node is Map) {
    final out = StringBuffer();
    for (final entry in node.entries) {
      final k = entry.key;
      final v = entry.value;
      if (v is Map && v.isNotEmpty) {
        out.writeln('$indent$k:');
        out.write(_emitYaml(v, depth + 1));
      } else if (v is List && v.isNotEmpty) {
        out.writeln('$indent$k:');
        for (final item in v) {
          if (item is Map) {
            // Inline if small + scalar-only; otherwise block style
            if (_isSmallScalarMap(item)) {
              out.writeln('$indent  - { ${_inlineMap(item)} }');
            } else {
              out.write('$indent  -');
              final inner = _emitYaml(item, depth + 2).trimRight();
              // Re-indent the first line so it follows the dash
              final lines = inner.split('\n');
              if (lines.isNotEmpty) {
                final first = lines.first.trimLeft();
                out.writeln(' $first');
                for (final line in lines.skip(1)) {
                  out.writeln(line);
                }
              }
            }
          } else {
            out.writeln('$indent  - ${_emitScalar(item)}');
          }
        }
      } else {
        out.writeln('$indent$k: ${_emitScalar(v)}');
      }
    }
    return out.toString();
  }
  return '$indent${_emitScalar(node)}\n';
}

bool _isSmallScalarMap(Map m) =>
    m.length <= 4 &&
    m.values.every((v) => v is! Map && v is! List);

String _inlineMap(Map m) =>
    m.entries.map((e) => '${e.key}: ${_emitScalar(e.value)}').join(', ');

String _emitScalar(dynamic v) {
  if (v == null) return 'null';
  if (v is bool || v is num) return v.toString();
  final s = v.toString();
  // Quote if it looks like YAML would parse it as something else.
  if (s.isEmpty) return '""';
  if (s.contains('\n') || s.contains(': ') || s.contains('#') ||
      s.startsWith('-') || s.startsWith('*') || s.startsWith('!') ||
      s.startsWith('&') || s.startsWith('?') ||
      RegExp(r'^[\d.+\-]').hasMatch(s) ||
      ['true', 'false', 'null', 'yes', 'no', 'on', 'off'].contains(s.toLowerCase())) {
    return '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }
  return s;
}
