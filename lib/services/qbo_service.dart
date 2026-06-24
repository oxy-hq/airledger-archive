import 'dart:async';

import '../models/quickbooks_config.dart';
import '../models/view_schema.dart';
import 'qbo_client.dart';
import 'qbo_push_store.dart';
import 'sheets_repository.dart' show Record;

/// Drains not-yet-pushed transactions for a QBO-mapped view to QuickBooks
/// as inventory-quantity changes, tracking per-transaction status in
/// [QboPushStore].
///
/// All pushes are **serialized** through one lock: every QtyOnHand write
/// needs the item's current SyncToken, so two concurrent pushes to the same
/// item would 409 and silently drop a delta. Serializing also bounds the
/// crash window between a successful QBO write and recording it locally.
class QboService {
  final QuickBooksConfig config;
  final QboClient client;

  QboService(this.config) : client = QboClient(config);

  Future<void> _lock = Future.value();

  /// Serialize [fn] after any in-flight push.
  Future<T> _serialized<T>(Future<T> Function() fn) {
    final next = _lock.then((_) => fn());
    // Keep the chain alive even if a push throws.
    _lock = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// Push every pending transaction in [rows] for [view]/[spec]. Already-
  /// pushed rows are skipped. One row failing doesn't stop the rest.
  Future<QboPushSummary> pushPending(
    ViewSchema view,
    QboPushSpec spec,
    List<Record> rows,
  ) async {
    var pushed = 0, failed = 0, skipped = 0;
    final ids = [
      for (final r in rows)
        if (r['id'] != null) r['id'].toString(),
    ];
    final statuses = await QboPushStore.statusesFor(view.name, ids);
    for (final row in rows) {
      final id = row['id']?.toString();
      if (id == null) {
        skipped++;
        continue;
      }
      if (statuses[id]?.status == QboPushStatus.pushed) {
        skipped++;
        continue;
      }
      final ok = await pushOne(view, spec, row);
      if (ok) {
        pushed++;
      } else {
        failed++;
      }
    }
    return QboPushSummary(pushed: pushed, failed: failed, skipped: skipped);
  }

  /// Push a single transaction. Returns true on success. Records status in
  /// [QboPushStore] either way. Used by [pushPending] and by per-row retry.
  Future<bool> pushOne(ViewSchema view, QboPushSpec spec, Record row) {
    return _serialized(() async {
      final id = row['id']?.toString();
      if (id == null) return false;
      final sku = row[spec.skuDimension]?.toString();
      final qty = _asNum(row[spec.qtyDimension]);
      if (sku == null || sku.isEmpty || qty == null) {
        await QboPushStore.set(view.name, id, QboPushStatus.failed,
            error: 'Row missing ${spec.skuDimension}/${spec.qtyDimension}');
        return false;
      }
      final delta = spec.signedDelta(qty);
      await QboPushStore.set(view.name, id, QboPushStatus.pushing);
      try {
        final item = await client.queryItemByName(sku);
        if (item == null) {
          await QboPushStore.set(view.name, id, QboPushStatus.failed,
              error: 'No QuickBooks item named "$sku"');
          return false;
        }
        final updated =
            await client.sparseUpdateQtyOnHand(item, item.qtyOnHand + delta);
        await QboPushStore.set(
          view.name,
          id,
          QboPushStatus.pushed,
          qboItemId: updated.id,
          appliedDelta: delta,
          syncToken: updated.syncToken,
        );
        return true;
      } catch (e) {
        await QboPushStore.set(view.name, id, QboPushStatus.failed,
            error: e.toString());
        return false;
      }
    });
  }

  /// Current statuses for the given transaction [ids] (for badge rendering).
  Future<Map<String, QboPushRecord>> statusesFor(
    String view,
    Iterable<String> ids,
  ) =>
      QboPushStore.statusesFor(view, ids);

  num? _asNum(Object? v) {
    if (v is num) return v;
    if (v == null) return null;
    return num.tryParse(v.toString());
  }
}

class QboPushSummary {
  final int pushed;
  final int failed;
  final int skipped;
  const QboPushSummary({
    required this.pushed,
    required this.failed,
    required this.skipped,
  });
}
