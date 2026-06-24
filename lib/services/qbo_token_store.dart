import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Persists QuickBooks OAuth tokens in a local SQLite file (`qbo.db`),
/// one row per realm. **Persistence is mandatory**: QBO rotates the
/// refresh token on (nearly) every refresh, invalidating the previous one,
/// so we must store the latest or the integration locks itself out. Kept
/// in its own DB so token writes can't be lost to a row-cache wipe.
///
/// CLAUDE.md forbids a secure-storage dependency; tokens live here in plain
/// SQLite, no worse than the API secrets already baked into the APK.
class QboTokens {
  final String accessToken;
  final String refreshToken;

  /// Epoch millis when the access token expires (it's good for ~60 min).
  final int accessExpiresAt;

  const QboTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
  });

  bool isFresh({Duration skew = const Duration(minutes: 2)}) =>
      DateTime.now().millisecondsSinceEpoch <
      accessExpiresAt - skew.inMilliseconds;
}

class QboTokenStore {
  static Database? _db;

  static Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getApplicationDocumentsDirectory();
    final db = await openDatabase(
      p.join(dir.path, 'qbo.db'),
      version: 1,
      onCreate: (db, _) => db.execute(
        'CREATE TABLE tokens ('
        'realm_id TEXT PRIMARY KEY, '
        'access_token TEXT NOT NULL, '
        'refresh_token TEXT NOT NULL, '
        'access_expires_at INTEGER NOT NULL)',
      ),
    );
    _db = db;
    return db;
  }

  static Future<QboTokens?> load(String realmId) async {
    final db = await _open();
    final res = await db.query(
      'tokens',
      where: 'realm_id = ?',
      whereArgs: [realmId],
      limit: 1,
    );
    if (res.isEmpty) return null;
    final r = res.first;
    return QboTokens(
      accessToken: r['access_token'] as String,
      refreshToken: r['refresh_token'] as String,
      accessExpiresAt: r['access_expires_at'] as int,
    );
  }

  static Future<void> save(String realmId, QboTokens tokens) async {
    final db = await _open();
    await db.insert(
      'tokens',
      {
        'realm_id': realmId,
        'access_token': tokens.accessToken,
        'refresh_token': tokens.refreshToken,
        'access_expires_at': tokens.accessExpiresAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
