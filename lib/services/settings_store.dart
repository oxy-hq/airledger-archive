import 'package:shared_preferences/shared_preferences.dart';

/// Backend type for the data store. Currently only Google Sheets is wired
/// up, but the enum makes it easy to add SQLite / Postgres / etc later.
enum DbType { sheets }

/// User-configurable settings, persisted in shared_preferences. Override the
/// bundled `assets/config.yaml` at runtime so the user can change the
/// spreadsheet, point at a different schemas repo, or rebrand the app
/// without rebuilding the APK.
class Settings {
  final DbType dbType;

  /// Spreadsheet ID (raw) or full URL. Use [parseSpreadsheetId] to extract
  /// the canonical ID for the Sheets API.
  final String? spreadsheetIdRaw;

  /// e.g. `rsyi/ledger-schemas`.
  final String? githubRepo;
  final String githubBranch;
  final String? githubToken;

  final DateTime? lastSync;

  Settings({
    required this.dbType,
    this.spreadsheetIdRaw,
    this.githubRepo,
    this.githubBranch = 'main',
    this.githubToken,
    this.lastSync,
  });

  Settings copyWith({
    DbType? dbType,
    String? spreadsheetIdRaw,
    String? githubRepo,
    String? githubBranch,
    String? githubToken,
    DateTime? lastSync,
  }) {
    return Settings(
      dbType: dbType ?? this.dbType,
      spreadsheetIdRaw: spreadsheetIdRaw ?? this.spreadsheetIdRaw,
      githubRepo: githubRepo ?? this.githubRepo,
      githubBranch: githubBranch ?? this.githubBranch,
      githubToken: githubToken ?? this.githubToken,
      lastSync: lastSync ?? this.lastSync,
    );
  }

  /// Returns the canonical spreadsheet id from either a raw id or a full URL
  /// like `https://docs.google.com/spreadsheets/d/<ID>/edit`.
  String? get spreadsheetId => parseSpreadsheetId(spreadsheetIdRaw);

  static String? parseSpreadsheetId(String? input) {
    if (input == null) return null;
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    final m = RegExp(r'/spreadsheets/d/([a-zA-Z0-9_\-]+)').firstMatch(trimmed);
    if (m != null) return m.group(1);
    return trimmed;
  }
}

class SettingsStore {
  static const _kDbType = 'settings.db_type';
  static const _kSpreadsheetId = 'settings.spreadsheet_id';
  static const _kGithubRepo = 'settings.github_repo';
  static const _kGithubBranch = 'settings.github_branch';
  static const _kGithubToken = 'settings.github_token';
  static const _kLastSync = 'settings.last_sync';

  static Future<Settings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final dbTypeName = prefs.getString(_kDbType);
    final lastSyncStr = prefs.getString(_kLastSync);
    return Settings(
      dbType: DbType.values.firstWhere(
        (e) => e.name == dbTypeName,
        orElse: () => DbType.sheets,
      ),
      spreadsheetIdRaw: prefs.getString(_kSpreadsheetId),
      githubRepo: prefs.getString(_kGithubRepo),
      githubBranch: prefs.getString(_kGithubBranch) ?? 'main',
      githubToken: prefs.getString(_kGithubToken),
      lastSync:
          lastSyncStr == null ? null : DateTime.tryParse(lastSyncStr),
    );
  }

  /// Persists [s]. Empty-string fields clear the underlying key.
  static Future<void> save(Settings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDbType, s.dbType.name);
    await _writeOrRemove(prefs, _kSpreadsheetId, s.spreadsheetIdRaw);
    await _writeOrRemove(prefs, _kGithubRepo, s.githubRepo);
    await prefs.setString(_kGithubBranch, s.githubBranch);
    await _writeOrRemove(prefs, _kGithubToken, s.githubToken);
  }

  static Future<void> markSynced(DateTime t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastSync, t.toIso8601String());
  }

  static Future<void> _writeOrRemove(
      SharedPreferences prefs, String key, String? value) async {
    if (value == null || value.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, value);
    }
  }
}
