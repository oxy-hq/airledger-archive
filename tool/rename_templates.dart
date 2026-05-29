// ignore_for_file: avoid_print
//
// One-shot migration: moves templates from
//
//   <repo>/templates/<view>/<template_name>.yml
//
// to the oxy-style basename-paired convention:
//
//   <repo>/views/<view>.<template_name>.template.yml
//
// Drops the now-redundant top-level `view:` field from each template
// (the filename's basename implies it).
//
// Usage:
//   dart run tool/rename_templates.dart <repo-root>
//
// The script:
//   - reads <repo-root>/templates/<view>/*.yml
//   - for each, writes <repo-root>/views/<view>.<template_basename>.template.yml
//   - prints summary
//   - leaves the original templates/ tree in place (delete by hand once
//     confirmed; or pass --delete to remove)

import 'dart:io';

import 'package:path/path.dart' as p;

Future<int> main(List<String> argv) async {
  if (argv.isEmpty || argv.contains('-h') || argv.contains('--help')) {
    print('Usage: dart run tool/rename_templates.dart <repo-root> [--delete]');
    return argv.isEmpty ? 1 : 0;
  }
  final repoRoot = Directory(argv.first);
  if (!repoRoot.existsSync()) {
    print('error: repo root not found: ${repoRoot.path}');
    return 1;
  }
  final shouldDelete = argv.contains('--delete');

  final templatesDir = Directory(p.join(repoRoot.path, 'templates'));
  if (!templatesDir.existsSync()) {
    print('No templates/ dir at ${repoRoot.path} — nothing to do');
    return 0;
  }
  final viewsDir = Directory(p.join(repoRoot.path, 'views'));
  if (!viewsDir.existsSync()) {
    print('error: views/ dir missing at ${repoRoot.path}');
    return 1;
  }

  int count = 0;
  for (final viewSubdir in templatesDir.listSync().whereType<Directory>()) {
    final viewName = p.basename(viewSubdir.path);
    final files = viewSubdir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.yml'))
        .toList();
    for (final f in files) {
      final templateBase = p.basenameWithoutExtension(f.path); // e.g. cut_deadlift_heavy
      final target = File(
        p.join(viewsDir.path, '$viewName.$templateBase.template.yml'),
      );
      // Read, strip the `view:` back-pointer (line starting with `view:` at
      // root level only), write.
      final original = f.readAsStringSync();
      final cleaned = _stripViewBackpointer(original);
      target.writeAsStringSync(cleaned);
      print('  ${f.path}  →  ${target.path}');
      count++;
    }
  }
  print('moved $count template(s)');

  if (shouldDelete && count > 0) {
    templatesDir.deleteSync(recursive: true);
    print('removed ${templatesDir.path}');
  } else if (count > 0) {
    print('Left ${templatesDir.path} in place. Re-run with --delete to '
        'clean it up, or `rm -r` by hand.');
  }
  return 0;
}

/// Removes a top-level `view: <name>` line. Naive but sufficient — template
/// files have a `view:` at the root, no nested `view:` keys.
String _stripViewBackpointer(String src) {
  final lines = src.split('\n');
  final out = <String>[];
  for (final line in lines) {
    if (RegExp(r'^view:\s').hasMatch(line)) continue;
    out.add(line);
  }
  return out.join('\n');
}
