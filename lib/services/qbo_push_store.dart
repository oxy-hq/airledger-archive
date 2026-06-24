import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Per-transaction QuickBooks push status. This is the "have we pushed this
/// transaction to the external system?" ledger that makes the
/// state-tracking integration safe: a transaction's inventory delta is
/// applied to QBO exactly once, and the timeline can badge each row.
///
/// Keyed by `(view, txn_id)` where `txn_id` is the transaction's `id`
/// dimension. A row absent from the table is [QboPushStatus.pending]
/// (never pushed). Stored in its own `qbo_push.db` so it survives schema
/// syncs and row-cache wipes — it's source-of-truth for idempotency.
enum QboPushStatus { pending, pushing, pushed, failed }

class QboPushRecord {
  final QboPushStatus status;
  final String? qboItemId;
  final double? appliedDelta;
  final String? error;

  const QboPushRecord({
    required this.status,
    this.qboItemId,
    this.appliedDelta,
    this.error,
  });

  static const pending = QboPushRecord(status: QboPushStatus.pending);
}

class QboPushStore {
  static Database? _db;

  static Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getApplicationDocumentsDirectory();
    final db = await openDatabase(
      p.join(dir.path, 'qbo_push.db'),
      version: 1,
      onCreate: (db, _) => db.execute(
        'CREATE TABLE push ('
        'view TEXT NOT NULL, '
        'txn_id TEXT NOT NULL, '
        'status TEXT NOT NULL, '
        'qbo_item_id TEXT, '
        'applied_delta REAL, '
        'synctoken TEXT, '
        'error TEXT, '
        'updated_at INTEGER NOT NULL, '
        'PRIMARY KEY (view, txn_id))',
      ),
    );
    _db = db;
    return db;
  }

  /// Statuses for the given transaction [ids] in [view]. Ids with no row
  /// are reported as [QboPushStatus.pending]. Best-effort: returns all
  /// pending if the DB can't be read.
  static Future<Map<String, QboPushRecord>> statusesFor(
    String view,
    Iterable<String> ids,
  ) async {
    final out = {for (final id in ids) id: QboPushRecord.pending};
    try {
      final db = await _open();
      final res = await db.query('push', where: 'view = ?', whereArgs: [view]);
      for (final r in res) {
        final id = r['txn_id'] as String;
        if (!out.containsKey(id)) continue;
        out[id] = QboPushRecord(
          status: _parse(r['status'] as String),
          qboItemId: r['qbo_item_id'] as String?,
          appliedDelta: (r['applied_delta'] as num?)?.toDouble(),
          error: r['error'] as String?,
        );
      }
    } catch (_) {/* treat as all-pending */}
    return out;
  }

  static Future<void> set(
    String view,
    String txnId,
    QboPushStatus status, {
    String? qboItemId,
    double? appliedDelta,
    String? syncToken,
    String? error,
  }) async {
    final db = await _open();
    await db.insert(
      'push',
      {
        'view': view,
        'txn_id': txnId,
        'status': status.name,
        'qbo_item_id': qboItemId,
        'applied_delta': appliedDelta,
        'synctoken': syncToken,
        'error': error,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static QboPushStatus _parse(String s) => QboPushStatus.values.firstWhere(
        (v) => v.name == s,
        orElse: () => QboPushStatus.pending,
      );
}
