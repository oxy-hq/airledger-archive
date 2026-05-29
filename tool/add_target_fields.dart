// ignore_for_file: avoid_print
//
// One-shot: adds the explicit `target:` field that points at the paired
// `.view.yml` file by full filename. Mirrors the oxy `.test.yml` →
// `target: <agent>.agent.yml` pattern (`~/customer-repos/pokehouse/
// pokehouse-oxy/oxy/tests/restaurant_analyst.operations.test.yml`).
//
// For `.input.yml` files: replaces any existing `view: <name>` line with
// `target: <name>.view.yml`. The view name is derived from the basename.
//
// For `.template.yml` files: prepends `target: <base>.view.yml` if no
// `target:` field is present. The view base comes from the first
// dotted segment of the basename.
//
// Idempotent — re-running is a no-op.
//
// Usage:
//   dart run tool/add_target_fields.dart <views-dir>

import 'dart:io';

Future<int> main(List<String> argv) async {
  if (argv.isEmpty) {
    print('Usage: dart run tool/add_target_fields.dart <views-dir>');
    return 1;
  }
  final dir = Directory(argv.first);
  if (!dir.existsSync()) {
    print('error: dir not found: ${dir.path}');
    return 1;
  }
  int patched = 0;
  for (final f in dir.listSync().whereType<File>()) {
    final base = f.path.split('/').last;
    if (base.endsWith('.input.yml')) {
      final viewBase = base.substring(0, base.length - '.input.yml'.length);
      if (_patchInput(f, viewBase)) patched++;
    } else if (base.endsWith('.template.yml')) {
      final viewBase = base.split('.').first;
      if (_patchTemplate(f, viewBase)) patched++;
    }
  }
  print('patched $patched file(s)');
  return 0;
}

bool _patchInput(File f, String viewBase) {
  final original = f.readAsStringSync();
  final lines = original.split('\n');
  final target = 'target: $viewBase.view.yml';
  if (lines.any((l) => l.trimRight() == target)) return false;
  final patched = <String>[];
  bool replaced = false;
  for (final line in lines) {
    if (RegExp(r'^view:\s').hasMatch(line) ||
        RegExp(r'^target:\s').hasMatch(line)) {
      if (!replaced) {
        patched.add(target);
        replaced = true;
      }
      // drop the old line
      continue;
    }
    patched.add(line);
  }
  if (!replaced) patched.insert(0, target);
  f.writeAsStringSync(patched.join('\n'));
  return true;
}

bool _patchTemplate(File f, String viewBase) {
  final original = f.readAsStringSync();
  final lines = original.split('\n');
  final target = 'target: $viewBase.view.yml';
  if (lines.any((l) => l.trimRight() == target)) return false;
  // Drop any preexisting `view:` or `target:` line at the top.
  final patched = <String>[];
  for (final line in lines) {
    if (RegExp(r'^view:\s').hasMatch(line) ||
        RegExp(r'^target:\s').hasMatch(line)) {
      continue;
    }
    patched.add(line);
  }
  patched.insert(0, target);
  f.writeAsStringSync(patched.join('\n'));
  return true;
}
