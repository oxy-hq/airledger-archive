// ignore_for_file: avoid_print
//
// Branded build CLI for ledger.
//
// Reads a branding config (defaults to `~/repos/ledger-schemas/ledger.yaml`)
// and turns the generic Ledger app into a custom-branded install on a
// connected Android device:
//
//   1. Writes `android/app/src/main/res/values/strings.xml` so the launcher
//      label changes (the manifest references `@string/app_name`).
//   2. Regenerates launcher icons via `flutter_launcher_icons` from the
//      icon path in the config.
//   3. Runs `tool/sync_assets.sh` so schemas/templates/apps/SA-key are
//      bundled fresh.
//   4. `flutter build apk --release`.
//   5. `adb install -r` + `adb shell monkey` (launches the app).
//
// Usage (from anywhere):
//   dart run ~/repos/ledger/tool/brand.dart
//   dart run ~/repos/ledger/tool/brand.dart --config /path/to/ledger.yaml
//   dart run ~/repos/ledger/tool/brand.dart --device 57041FDCH002VN
//
// ledger.yaml schema (all fields except app_name optional):
//   app_name: "Fitness Logger"
//   icon: assets/fitness-icon.png        # path relative to the yaml
//   adb_device: 57041FDCH002VN           # optional default device
//   skip_icons: false                    # skip the icon regen step

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const _defaultConfig = '~/repos/ledger-schemas/ledger.yaml';
const _ledgerRepo = '~/repos/ledger';
const _defaultPackage = 'com.robertyi.ledger';

Future<int> main(List<String> argv) async {
  final args = _parseArgs(argv);
  final configPath = _expand(args['config'] ?? _defaultConfig);
  final ledgerDir = Directory(_expand(_ledgerRepo));
  if (!ledgerDir.existsSync()) {
    print('error: ledger repo not found at ${ledgerDir.path}');
    return 1;
  }
  final config = _BrandConfig.load(configPath);

  print('› Branding: ${config.appName}'
      '${config.iconAbsolute != null ? "  icon=${p.basename(config.iconAbsolute!)}" : ""}');

  // 1. strings.xml
  _writeStringsXml(ledgerDir, config.appName);

  // 2. applicationId — only patch & clean when switching to a new package.
  // Switching applicationId without a clean leaves stale build artifacts
  // that confuse the install (e.g. INSTALL_FAILED_UPDATE_INCOMPATIBLE).
  final gradleFile = File(p.join(
      ledgerDir.path, 'android', 'app', 'build.gradle.kts'));
  final previousAppId = _readApplicationId(gradleFile);
  if (previousAppId != config.packageId) {
    _patchApplicationId(gradleFile, config.packageId);
    print('› applicationId: $previousAppId → ${config.packageId}');
    final r = await _run('flutter', ['clean'], workingDir: ledgerDir.path);
    if (r != 0) return r;
  }

  // 3. icons
  if (config.iconAbsolute != null && !config.skipIcons) {
    _writeLauncherIconConfig(ledgerDir, config.iconAbsolute!);
    final r = await _run('dart',
        ['run', 'flutter_launcher_icons', '-f', 'flutter_launcher_icons.yaml'],
        workingDir: ledgerDir.path);
    if (r != 0) return r;
  } else if (config.skipIcons) {
    print('› Skipping icon regen (skip_icons: true)');
  }

  // 4. sync_assets.sh — point at this config's schemas repo.
  final configDir = p.dirname(File(configPath).absolute.path);
  final syncSh = File(p.join(ledgerDir.path, 'tool', 'sync_assets.sh'));
  if (syncSh.existsSync()) {
    final r = await _run(
      'bash',
      [syncSh.path],
      workingDir: ledgerDir.path,
      environment: {
        'SCHEMAS_SRC': p.join(configDir, 'views'),
        'TEMPLATES_SRC': p.join(configDir, 'templates'),
        'APPS_SRC': p.join(configDir, 'apps'),
      },
    );
    if (r != 0) return r;
  }

  // 5. flutter build apk --release
  final r1 = await _run('flutter', ['build', 'apk', '--release'],
      workingDir: ledgerDir.path);
  if (r1 != 0) return r1;

  // 5. adb install + launch
  final apk = p.join(
      ledgerDir.path, 'build', 'app', 'outputs', 'flutter-apk', 'app-release.apk');
  final adbDevice = args['device'] ?? config.adbDevice;
  final adbBase = adbDevice == null ? <String>[] : ['-s', adbDevice];
  final r2 = await _run('adb', [...adbBase, 'install', '-r', apk]);
  if (r2 != 0) return r2;
  final r3 = await _run('adb', [
    ...adbBase,
    'shell',
    'monkey',
    '-p',
    config.packageId,
    '-c',
    'android.intent.category.LAUNCHER',
    '1',
  ]);
  if (r3 != 0) return r3;

  print('\n✓ Installed and launched ${config.appName} '
      '(${config.packageId})');
  return 0;
}

Map<String, String> _parseArgs(List<String> argv) {
  final out = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--config' && i + 1 < argv.length) out['config'] = argv[++i];
    if (a == '--device' && i + 1 < argv.length) out['device'] = argv[++i];
    if (a == '-h' || a == '--help') {
      _printHelpAndExit();
    }
  }
  return out;
}

void _printHelpAndExit() {
  print('Usage: dart run ~/repos/ledger/tool/brand.dart [options]');
  print('  --config <path>   branding YAML (default $_defaultConfig)');
  print('  --device <serial> adb device serial');
  exit(0);
}

void _writeStringsXml(Directory ledgerDir, String appName) {
  final f = File(p.join(
    ledgerDir.path,
    'android',
    'app',
    'src',
    'main',
    'res',
    'values',
    'strings.xml',
  ));
  // XML-encode the name minimally.
  final escaped = appName
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  f.writeAsStringSync(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<resources>\n'
    '    <string name="app_name">$escaped</string>\n'
    '</resources>\n',
  );
  print('› Wrote res/values/strings.xml (app_name="$appName")');
}

void _writeLauncherIconConfig(Directory ledgerDir, String iconPath) {
  final f = File(p.join(ledgerDir.path, 'flutter_launcher_icons.yaml'));
  f.writeAsStringSync(
    'flutter_launcher_icons:\n'
    '  android: "ic_launcher"\n'
    '  ios: false\n'
    '  image_path: "$iconPath"\n'
    '  adaptive_icon_background: "#0A0A0A"\n'
    '  adaptive_icon_foreground: "$iconPath"\n',
  );
}

Future<int> _run(
  String exe,
  List<String> args, {
  String? workingDir,
  Map<String, String>? environment,
}) async {
  print('\$ $exe ${args.join(' ')}');
  final proc = await Process.start(
    exe,
    args,
    workingDirectory: workingDir,
    environment: environment,
    includeParentEnvironment: true,
    mode: ProcessStartMode.inheritStdio,
    runInShell: true,
  );
  return proc.exitCode;
}

String? _readApplicationId(File gradle) {
  final body = gradle.readAsStringSync();
  final m = RegExp(r'applicationId\s*=\s*"([^"]+)"').firstMatch(body);
  return m?.group(1);
}

void _patchApplicationId(File gradle, String newId) {
  final body = gradle.readAsStringSync();
  final patched = body.replaceFirst(
    RegExp(r'applicationId\s*=\s*"[^"]+"'),
    'applicationId = "$newId"',
  );
  gradle.writeAsStringSync(patched);
}

String _expand(String path) {
  if (path.startsWith('~/') || path == '~') {
    final home = Platform.environment['HOME'] ?? '';
    return p.join(home, path.substring(2));
  }
  return path;
}

class _BrandConfig {
  final String appName;
  final String? iconAbsolute;
  final String? adbDevice;
  final String packageId;
  final bool skipIcons;

  _BrandConfig({
    required this.appName,
    required this.iconAbsolute,
    required this.adbDevice,
    required this.packageId,
    required this.skipIcons,
  });

  static _BrandConfig load(String configPath) {
    final f = File(configPath);
    if (!f.existsSync()) {
      // No config: ship as default "Ledger" with no icon override.
      print('› No config at $configPath — using defaults');
      return _BrandConfig(
        appName: 'Ledger',
        iconAbsolute: null,
        adbDevice: null,
        packageId: _defaultPackage,
        skipIcons: true,
      );
    }
    final node = loadYaml(f.readAsStringSync()) as YamlMap;
    final iconRel = node['icon'] as String?;
    final iconAbs = iconRel == null
        ? null
        : p.normalize(p.join(p.dirname(f.path), iconRel));
    if (iconAbs != null && !File(iconAbs).existsSync()) {
      print('warning: icon $iconAbs not found — skipping icon regen');
    }
    return _BrandConfig(
      appName: (node['app_name'] as String?) ?? 'Ledger',
      iconAbsolute:
          (iconAbs != null && File(iconAbs).existsSync()) ? iconAbs : null,
      adbDevice: node['adb_device'] as String?,
      packageId: (node['package_id'] as String?) ?? _defaultPackage,
      skipIcons: (node['skip_icons'] as bool?) ?? false,
    );
  }
}
