import 'dart:io';

import 'package:path/path.dart' as p;

/// Result of an oxy `config.yml` lookup.
class OxyConfigLocation {
  /// Absolute path to the discovered `config.yml`.
  final String configPath;

  /// Project root — the directory holding the config, or the directory
  /// holding the `oxy/` subdir that holds the config.
  final String projectRoot;

  /// True when discovered via the `oxy/config.yml` (nested) form, false
  /// when discovered as a sibling `config.yml` directly at the root.
  final bool nestedUnderOxy;

  OxyConfigLocation({
    required this.configPath,
    required this.projectRoot,
    required this.nestedUnderOxy,
  });

  @override
  String toString() =>
      'OxyConfigLocation(config=$configPath, root=$projectRoot, nested=$nestedUnderOxy)';
}

/// Walks up from [from] looking for a `config.yml`. At each ancestor
/// level, checks both:
///   1. `./config.yml`              (root layout)
///   2. `./oxy/config.yml`          (customer-repos layout — config lives
///                                   inside an `oxy/` sibling)
///
/// Returns the first match. Mirrors airlayer's `find_project_root`
/// (`~/repos/airlayer/src/cli/mod.rs`) — see `docs/oxy-compatibility.md`
/// for why the dual lookup exists.
///
/// Returns null if no config is found before hitting the filesystem root.
OxyConfigLocation? findOxyConfig({required String from}) {
  var dir = Directory(p.absolute(from));
  while (true) {
    final direct = File(p.join(dir.path, 'config.yml'));
    if (direct.existsSync()) {
      return OxyConfigLocation(
        configPath: direct.path,
        projectRoot: dir.path,
        nestedUnderOxy: false,
      );
    }
    final nested = File(p.join(dir.path, 'oxy', 'config.yml'));
    if (nested.existsSync()) {
      return OxyConfigLocation(
        configPath: nested.path,
        projectRoot: dir.path,
        nestedUnderOxy: true,
      );
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null; // reached fs root
    dir = parent;
  }
}
