import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/quickbooks_config.dart';
import 'qbo_token_store.dart';

/// Thin client for the QuickBooks Online Accounting API, scoped to what the
/// inventory-push flow needs: refresh an access token (seeded refresh-token
/// OAuth, no backend), find an inventory Item, and sparse-update its
/// quantity on hand.
///
/// Mirrors [GithubClient]'s shape — a per-request timeout wrapper, bearer
/// auth, and a typed [QboException] carrying the HTTP status + reason.
///
/// **Inventory note:** QBO has no `InventoryAdjustment` entity (that's
/// Desktop-only). Stock is changed by a *sparse update* of the Item's
/// `QtyOnHand`, which is **absolute** — callers read [QboItem.qtyOnHand],
/// compute `current ± delta`, and pass the result to
/// [sparseUpdateQtyOnHand]. Every write needs the current `SyncToken`
/// (optimistic concurrency), so reads and writes must be paired and
/// serialized per item.
class QboClient {
  final QuickBooksConfig config;
  final http.Client _http;

  /// Minor version pins the API contract. 65 is recent enough for the
  /// inventory fields we use and broadly available.
  static const _minorVersion = '65';

  QboClient(this.config, {http.Client? httpClient})
      : _http = _TimeoutClient(
          httpClient ?? http.Client(),
          const Duration(seconds: 30),
        );

  Future<String>? _refreshing;

  /// Returns a valid access token, refreshing if the stored one is stale or
  /// absent. Concurrent callers share a single in-flight refresh so we
  /// don't burn (and invalidate) refresh tokens by racing.
  Future<String> _accessToken() async {
    final stored = await QboTokenStore.load(config.realmId);
    if (stored != null && stored.isFresh()) return stored.accessToken;
    return _refreshing ??= _refresh(stored?.refreshToken).whenComplete(() {
      _refreshing = null;
    });
  }

  /// Exchanges a refresh token for a fresh access token, persisting the
  /// rotated refresh token. Falls back to the config's seed token when the
  /// store is empty (first run).
  Future<String> _refresh(String? storedRefresh) async {
    final refreshToken = storedRefresh ?? config.seedRefreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      throw QboException(
        op: 'refresh token',
        status: 0,
        message: 'No refresh token available — seed quickbooks.refresh_token '
            '(via refresh_token_var) from the OAuth Playground once.',
      );
    }
    final basic =
        base64.encode(utf8.encode('${config.clientId}:${config.clientSecret}'));
    final resp = await _http.post(
      Uri.parse(QuickBooksConfig.tokenEndpoint),
      headers: {
        'Authorization': 'Basic $basic',
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {'grant_type': 'refresh_token', 'refresh_token': refreshToken},
    );
    _check(resp, 'refresh token');
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final access = body['access_token'] as String;
    final expiresIn = (body['expires_in'] as num?)?.toInt() ?? 3600;
    // QBO returns a rotated refresh token — persist it or we lock out.
    final newRefresh = (body['refresh_token'] as String?) ?? refreshToken;
    await QboTokenStore.save(
      config.realmId,
      QboTokens(
        accessToken: access,
        refreshToken: newRefresh,
        accessExpiresAt:
            DateTime.now().millisecondsSinceEpoch + expiresIn * 1000,
      ),
    );
    return access;
  }

  Uri _company(String path) => Uri.parse(
        '${config.apiBase}/v3/company/${config.realmId}$path'
        '${path.contains('?') ? '&' : '?'}minorversion=$_minorVersion',
      );

  Future<Map<String, String>> _headers() async => {
        'Authorization': 'Bearer ${await _accessToken()}',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  /// Finds an inventory Item by its exact `Name`. Returns null if no item
  /// matches. Throws on API/auth failure.
  Future<QboItem?> queryItemByName(String name) async {
    // Escape single quotes for the QBO SQL-ish query language.
    final escaped = name.replaceAll("'", r"\'");
    final query = "select Id, SyncToken, QtyOnHand, Name from Item "
        "where Name = '$escaped'";
    final url = _company('/query?query=${Uri.encodeQueryComponent(query)}');
    final resp = await _http.get(url, headers: await _headers());
    _check(resp, 'query item "$name"');
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (body['QueryResponse'] as Map<String, dynamic>?)?['Item'];
    if (items is! List || items.isEmpty) return null;
    return QboItem.fromJson(items.first as Map<String, dynamic>);
  }

  /// Sparse-updates [item]'s `QtyOnHand` to [newQty] (absolute). Returns the
  /// updated item (with the advanced SyncToken). The caller is responsible
  /// for having computed `newQty = item.qtyOnHand ± delta`.
  ///
  /// **`InvStartDate` is required.** Without it QBO returns 200 but silently
  /// ignores the quantity change (the SyncToken doesn't even advance) — it
  /// re-sets the item's opening-balance inventory transaction as of this
  /// date and recomputes QtyOnHand from it.
  Future<QboItem> sparseUpdateQtyOnHand(QboItem item, num newQty) async {
    final now = DateTime.now();
    final invStartDate = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final resp = await _http.post(
      _company('/item'),
      headers: await _headers(),
      body: jsonEncode({
        'sparse': true,
        'Id': item.id,
        'SyncToken': item.syncToken,
        'QtyOnHand': newQty,
        'InvStartDate': invStartDate,
      }),
    );
    _check(resp, 'update item ${item.id} qty');
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return QboItem.fromJson(body['Item'] as Map<String, dynamic>);
  }

  void close() => _http.close();

  void _check(http.Response resp, String op) {
    if (resp.statusCode >= 200 && resp.statusCode < 300) return;
    String reason = resp.body;
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map) {
        // QBO error envelope: {Fault:{Error:[{Message,Detail}]}}
        final fault = decoded['Fault'];
        if (fault is Map && fault['Error'] is List && (fault['Error'] as List).isNotEmpty) {
          final err = (fault['Error'] as List).first as Map;
          reason = '${err['Message']}: ${err['Detail']}';
        } else if (decoded['error_description'] is String) {
          reason = decoded['error_description'] as String;
        }
      }
    } catch (_) {}
    throw QboException(op: op, status: resp.statusCode, message: reason);
  }
}

/// The subset of a QBO inventory Item the push flow reads.
class QboItem {
  final String id;
  final String syncToken;
  final num qtyOnHand;
  final String name;

  const QboItem({
    required this.id,
    required this.syncToken,
    required this.qtyOnHand,
    required this.name,
  });

  factory QboItem.fromJson(Map<String, dynamic> j) => QboItem(
        id: j['Id'].toString(),
        syncToken: j['SyncToken'].toString(),
        qtyOnHand: (j['QtyOnHand'] as num?) ?? 0,
        name: (j['Name'] as String?) ?? '',
      );
}

class QboException implements Exception {
  final String op;
  final int status;
  final String message;
  QboException({required this.op, required this.status, required this.message});

  @override
  String toString() => 'QuickBooks $op failed ($status): $message';
}

/// Per-request timeout so a stuck QBO call surfaces a clear error instead of
/// hanging the push loop. Mirrors GithubClient's wrapper.
class _TimeoutClient extends http.BaseClient {
  final http.Client _inner;
  final Duration timeout;

  _TimeoutClient(this._inner, this.timeout);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    try {
      return await _inner.send(request).timeout(timeout);
    } on TimeoutException {
      throw http.ClientException(
        'Timed out after ${timeout.inSeconds}s: '
        '${request.method} ${request.url.path}',
        request.url,
      );
    }
  }

  @override
  void close() => _inner.close();
}
