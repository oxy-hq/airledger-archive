// ignore_for_file: avoid_print

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:uuid/uuid.dart';

/// Parses a QuickBooks "items" copy-paste (one blank-line-separated record
/// per inventory item) and writes the parsed rows to the ledger workbook's
/// `inventory` tab. Use the inventory.view.yml schema for the target
/// columns.
///
/// The paste format is irregular — every item has at least these lines:
///   name
///   sales_description (often == name)
///   ... 0–2 optional context lines (description, qty-on-hand, status word)
///   cost_group (one of the known categories below)
///   type        (Inventory | Service | Non-Inventory)
///   price       (optional)
///   cost        (optional)
///
/// We walk lines one item at a time, using the cost_group sentinel to know
/// where the "header" ends.
///
/// Run:
///   dart run tool/migrate_inventory.dart /tmp/inventory_paste.txt --confirm
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('usage: dart run tool/migrate_inventory.dart <paste.txt> [--confirm]');
    exit(1);
  }
  final pastePath = args[0];
  final confirmed = args.contains('--confirm');

  final raw = await File(pastePath).readAsString();
  final items = _parsePaste(raw);
  print('parsed ${items.length} items');
  for (final skipped in items.where((i) => i.skipReason != null)) {
    print('  SKIP: ${skipped.skipReason} :: ${skipped.rawBlock.take(60).toString()}...');
  }
  final usable = items.where((i) => i.skipReason == null).toList();
  print('${usable.length} usable items');

  // Summary by category for sanity.
  final byCat = <String, int>{};
  for (final it in usable) {
    byCat[it.costGroup ?? '(none)'] =
        (byCat[it.costGroup ?? '(none)'] ?? 0) + 1;
  }
  for (final e in byCat.entries) {
    print('  ${e.value.toString().padLeft(4)}  ${e.key}');
  }

  if (!confirmed) {
    print('\n(dry run; pass --confirm to write to sheet)');
    exit(0);
  }

  const destId = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';
  const destTab = 'inventory';
  const uuid = Uuid();

  final destHeaders = <String>[
    'id',
    'Name',
    'Description',
    'Qty On Hand',
    'Status',
    'Cost Group',
    'Type',
    'Price',
    'Cost',
  ];

  final home = Platform.environment['HOME']!;
  final keyJson = await File(
    '$home/.config/ledger/service-account.json',
  ).readAsString();
  final api = sheets.SheetsApi(
    await clientViaServiceAccount(
      ServiceAccountCredentials.fromJson(keyJson),
      [sheets.SheetsApi.spreadsheetsScope],
    ),
  );

  print('\nensuring $destTab tab exists ...');
  final ss = await api.spreadsheets.get(destId);
  final tabExists = (ss.sheets ?? []).any(
    (s) => s.properties?.title == destTab,
  );
  if (!tabExists) {
    await api.spreadsheets.batchUpdate(
      sheets.BatchUpdateSpreadsheetRequest(requests: [
        sheets.Request(
          addSheet: sheets.AddSheetRequest(
            properties: sheets.SheetProperties(title: destTab),
          ),
        ),
      ]),
      destId,
    );
    print('  created');
  } else {
    print('  exists');
  }

  print('clearing + writing headers ...');
  await api.spreadsheets.values.clear(
    sheets.ClearValuesRequest(),
    destId,
    "'$destTab'!A:Z",
  );
  await api.spreadsheets.values.update(
    sheets.ValueRange(values: [destHeaders]),
    destId,
    "'$destTab'!A1",
    valueInputOption: 'RAW',
  );

  print('writing ${usable.length} items ...');
  final rows = usable
      .map((i) => <Object?>[
            uuid.v4(),
            i.name,
            i.description ?? '',
            i.qty ?? '',
            i.status ?? '',
            i.costGroup ?? '',
            i.type ?? '',
            i.price ?? '',
            i.cost ?? '',
          ])
      .toList();
  await api.spreadsheets.values.update(
    sheets.ValueRange(values: rows),
    destId,
    "'$destTab'!A2",
    valueInputOption: 'RAW',
  );
  print('DONE');
  exit(0);
}

const _knownCostGroups = <String>{
  'Uniforms',
  'Store Supplies',
  'Packaging',
  'Sauces',
  'Food Product',
  'Produce',
  'Seafood',
  'Drinks',
  'Catering',
  'Fees & Reimbursements',
  'Uncategorized',
  'Credit Memo',
};

const _knownTypes = <String>{
  'Inventory',
  'Service',
  'Non-Inventory',
};

const _statusWords = <String>{'Out', 'Low'};

class _Item {
  final List<String> rawBlock;
  String? name;
  String? description;
  num? qty;
  String? status;
  String? costGroup;
  String? type;
  num? price;
  num? cost;
  String? skipReason;
  _Item(this.rawBlock);
}

List<_Item> _parsePaste(String text) {
  final blocks = <List<String>>[];
  var current = <String>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) {
      if (current.isNotEmpty) {
        blocks.add(current);
        current = <String>[];
      }
      continue;
    }
    current.add(line);
  }
  if (current.isNotEmpty) blocks.add(current);
  return blocks.map(_parseBlock).toList();
}

_Item _parseBlock(List<String> block) {
  final item = _Item(block);

  // Find the cost_group line — it's the dividing wall between "header"
  // (name/description/qty/status) and "type/price/cost".
  final cgIdx = block.indexWhere(_knownCostGroups.contains);
  if (cgIdx < 0) {
    item.skipReason = 'no recognized cost group';
    return item;
  }
  item.costGroup = block[cgIdx];

  // Header (everything before cost_group):
  //   block[0]              = name
  //   block[1]              = sales description (usually == name)
  //   middle (0..3 lines)   = optional description, qty, status
  if (block.length < 2) {
    item.skipReason = 'block too short';
    return item;
  }
  item.name = block[0];
  // skip block[1] (sales description, redundant)

  // Strip out any rogue header words that appear in the QB-table-header noise
  // (the "Dinner Napkins\nName\nSales Description\n..." entry).
  final headerNoise = <String>{
    'Name',
    'Sales Description',
    'Qty on hand',
    'Cost group',
    'Category',
    'SKU',
    'Type',
    'Price',
    'Cost',
    'Actions',
    'Discount',
  };
  final headerLines = block.sublist(2, cgIdx);
  if (headerLines.any(headerNoise.contains)) {
    item.skipReason = 'block contains QB table-header noise';
    return item;
  }

  final descLines = <String>[];
  for (final line in headerLines) {
    if (_statusWords.contains(line)) {
      // 'Out' wins over 'Low' if both appear.
      if (item.status == null || line == 'Out') item.status = line;
      continue;
    }
    final n = num.tryParse(line.replaceAll(',', ''));
    if (n != null && item.qty == null) {
      item.qty = n;
      continue;
    }
    // Anything else: descriptive text.
    descLines.add(line);
  }
  if (descLines.isNotEmpty) item.description = descLines.join(' · ');

  // Footer (everything after cost_group):
  //   block[cgIdx+1]        = type
  //   block[cgIdx+2]        = price (optional)
  //   block[cgIdx+3]        = cost (optional)
  if (cgIdx + 1 < block.length) {
    final typeStr = block[cgIdx + 1];
    if (_knownTypes.contains(typeStr)) {
      item.type = typeStr;
    } else {
      // Unknown type — keep the value to surface during review.
      item.type = typeStr;
    }
  }
  if (cgIdx + 2 < block.length) {
    item.price = num.tryParse(block[cgIdx + 2].replaceAll(',', ''));
  }
  if (cgIdx + 3 < block.length) {
    item.cost = num.tryParse(block[cgIdx + 3].replaceAll(',', ''));
  }

  return item;
}
