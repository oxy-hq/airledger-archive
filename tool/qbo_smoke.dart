// ignore_for_file: avoid_print
//
// Standalone QuickBooks Online smoke test — validates your sandbox (or
// production) credentials and the exact calls the app makes, WITHOUT
// building/installing the Flutter app. Run it the moment you've put the
// four QBO_* vars in a .env file.
//
// Usage:
//   dart run tool/qbo_smoke.dart "<Item Name>"
//   dart run tool/qbo_smoke.dart "<Item Name>" --add 5
//   dart run tool/qbo_smoke.dart "<Item Name>" --env ~/repos/pokehouse-ledger/.env
//   dart run tool/qbo_smoke.dart "<Item Name>" --production
//
// What it does:
//   1. Refreshes an access token from QBO_REFRESH_TOKEN (this ROTATES the
//      refresh token — it prints the NEW one; update your .env with it).
//   2. Looks up the inventory item by exact Name and prints Id / SyncToken
//      / QtyOnHand.
//   3. With --add <delta>, sparse-updates QtyOnHand by the (signed) delta
//      and prints the new quantity — exactly what the app's "Update" does.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const _tokenEndpoint =
    'https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer';
const _minorVersion = '65';

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final listMode = args.contains('--list');
  if (!listMode && positional.isEmpty) {
    print('Usage: dart run tool/qbo_smoke.dart "<Item Name>" '
        '[--add <delta>] [--env <path>] [--production]');
    print('   or: dart run tool/qbo_smoke.dart --list   '
        '(list inventory items)');
    exit(64);
  }
  final itemName = positional.isEmpty ? null : positional.first;
  final production = args.contains('--production');
  final addDelta = _flagValue(args, '--add');
  final envPath = _flagValue(args, '--env') ??
      '${Platform.environment['HOME']}/repos/pokehouse-ledger/.env';

  final env = {...Platform.environment, ..._loadEnv(envPath)};
  final clientId = _require(env, 'QBO_CLIENT_ID');
  final clientSecret = _require(env, 'QBO_CLIENT_SECRET');
  final realmId = _require(env, 'QBO_REALM_ID');
  final refreshToken = _require(env, 'QBO_REFRESH_TOKEN');

  final base = production
      ? 'https://quickbooks.api.intuit.com'
      : 'https://sandbox-quickbooks.api.intuit.com';
  print('• Environment: ${production ? "PRODUCTION" : "sandbox"}  '
      'realm=$realmId');
  print('• client_id=${clientId.substring(0, 8)}…  '
      '(must match the Client ID shown for the app you pick in the Playground)');
  print('• refresh_token=${refreshToken.substring(0, 6)}…'
      '${refreshToken.substring(refreshToken.length - 4)}  '
      '(len ${refreshToken.length})');
  print('• .env: $envPath');

  // 1) Refresh access token (rotates the refresh token).
  print('\n[1/3] Refreshing access token…');
  final basic = base64.encode(utf8.encode('$clientId:$clientSecret'));
  final tokenResp = await http.post(
    Uri.parse(_tokenEndpoint),
    headers: {
      'Authorization': 'Basic $basic',
      'Accept': 'application/json',
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: {'grant_type': 'refresh_token', 'refresh_token': refreshToken},
  );
  if (tokenResp.statusCode != 200) {
    print('  ✗ token refresh failed (${tokenResp.statusCode}): '
        '${tokenResp.body}');
    exit(1);
  }
  final tok = jsonDecode(tokenResp.body) as Map<String, dynamic>;
  final access = tok['access_token'] as String;
  final newRefresh = tok['refresh_token'] as String;
  print('  ✓ got access token (${access.substring(0, 12)}…)');
  if (newRefresh != refreshToken) {
    print('  ⚠ refresh token ROTATED. Update your .env:');
    print('      QBO_REFRESH_TOKEN=$newRefresh');
  }

  // --list: dump inventory items so we know what to target.
  if (listMode) {
    print('\n[2/2] Listing inventory items…');
    final lResp = await http.get(
      Uri.parse('$base/v3/company/$realmId/query'
          '?query=${Uri.encodeQueryComponent("select Id, Name, QtyOnHand, TrackQtyOnHand from Item where Type = 'Inventory' maxresults 100")}'
          '&minorversion=$_minorVersion'),
      headers: {
        'Authorization': 'Bearer $access',
        'Accept': 'application/json',
      },
    );
    if (lResp.statusCode != 200) {
      print('  ✗ query failed (${lResp.statusCode}): ${lResp.body}');
      exit(1);
    }
    final list =
        (jsonDecode(lResp.body)['QueryResponse'] as Map?)?['Item'] as List?;
    if (list == null || list.isEmpty) {
      print('  (no Inventory-type items found — create one in the '
          'sandbox: Sales → Products & services → New → Inventory)');
    } else {
      for (final it in list) {
        final m = it as Map<String, dynamic>;
        print('   • "${m['Name']}"  qty=${m['QtyOnHand'] ?? '-'}  '
            'id=${m['Id']}');
      }
    }
    print('\n✓ Credentials valid. Target one of these names with:'
        '\n    dart run tool/qbo_smoke.dart "<Name>" --add 5');
    return;
  }

  // 2) Query the item by exact Name. (Non-null here: list mode returned
  // above, and a missing name without --list exits early.)
  final name = itemName!;
  print('\n[2/3] Looking up item "$name"…');
  final query = "select Id, SyncToken, QtyOnHand, Name, Type, "
      "TrackQtyOnHand from Item where Name = '${name.replaceAll("'", r"\'")}'";
  final qResp = await http.get(
    Uri.parse('$base/v3/company/$realmId/query'
        '?query=${Uri.encodeQueryComponent(query)}&minorversion=$_minorVersion'),
    headers: {'Authorization': 'Bearer $access', 'Accept': 'application/json'},
  );
  if (qResp.statusCode != 200) {
    print('  ✗ query failed (${qResp.statusCode}): ${qResp.body}');
    exit(1);
  }
  final items =
      (jsonDecode(qResp.body)['QueryResponse'] as Map?)?['Item'] as List?;
  if (items == null || items.isEmpty) {
    print('  ✗ no item named "$name" in this company. '
        'Check the exact Name (case-sensitive) in QuickBooks.');
    exit(1);
  }
  final item = items.first as Map<String, dynamic>;
  final id = item['Id'].toString();
  final syncToken = item['SyncToken'].toString();
  final qty = (item['QtyOnHand'] as num?) ?? 0;
  print('  ✓ Id=$id  SyncToken=$syncToken  QtyOnHand=$qty  '
      'Type=${item['Type']}  TrackQtyOnHand=${item['TrackQtyOnHand']}');

  // 3) Optionally apply a delta (sparse update QtyOnHand).
  if (addDelta == null) {
    print('\n[3/3] (skipped — pass --add <delta> to adjust quantity)');
    print('\n✓ Smoke test passed: credentials valid, item readable.');
    return;
  }
  final delta = num.parse(addDelta);
  final newQty = qty + delta;
  // QBO ignores a QtyOnHand change unless InvStartDate is present — it
  // re-sets the opening-balance inventory transaction as of that date.
  final now = DateTime.now();
  final invStartDate = '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
  print('\n[3/3] Sparse-updating QtyOnHand: $qty ${delta >= 0 ? '+' : ''}'
      '$delta = $newQty  (InvStartDate=$invStartDate)…');
  final uResp = await http.post(
    Uri.parse(
        '$base/v3/company/$realmId/item?minorversion=$_minorVersion'),
    headers: {
      'Authorization': 'Bearer $access',
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'sparse': true,
      'Id': id,
      'SyncToken': syncToken,
      'QtyOnHand': newQty,
      'InvStartDate': invStartDate,
    }),
  );
  if (uResp.statusCode != 200) {
    print('  ✗ update failed (${uResp.statusCode}): ${uResp.body}');
    exit(1);
  }
  final updated = jsonDecode(uResp.body)['Item'] as Map<String, dynamic>;
  print('  ✓ QtyOnHand is now ${updated['QtyOnHand']} '
      '(SyncToken=${updated['SyncToken']})');
  print('\n✓ Full round-trip passed — this is exactly what the app does.');
}

String? _flagValue(List<String> args, String flag) {
  final i = args.indexOf(flag);
  if (i < 0 || i + 1 >= args.length) return null;
  return args[i + 1];
}

String _require(Map<String, String> env, String key) {
  final v = env[key];
  if (v == null || v.isEmpty) {
    print('✗ Missing $key (set it in your .env or environment).');
    exit(64);
  }
  return v;
}

Map<String, String> _loadEnv(String path) {
  final f = File(path);
  if (!f.existsSync()) return {};
  final out = <String, String>{};
  for (final line in f.readAsLinesSync()) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final eq = t.indexOf('=');
    if (eq < 0) continue;
    out[t.substring(0, eq).trim()] =
        t.substring(eq + 1).trim().replaceAll(RegExp(r'''^["']|["']$'''), '');
  }
  return out;
}
