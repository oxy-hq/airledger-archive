// ignore_for_file: avoid_print
import 'dart:io';
import 'package:ledger/services/schema_parser.dart';

void main(List<String> args) {
  final path = args.isNotEmpty
      ? args[0]
      : '/Users/robertyi/repos/ledger/assets/schemas/strength.view.yml';
  final yaml = File(path).readAsStringSync();
  try {
    final view = parseViewSchema(yaml);
    print('view: ${view.name}');
    print('table: ${view.table}');
    print('plannable: ${view.plannable?.logField} / ${view.plannable?.logFormat}');
    print('dimensions: ${view.dimensions.map((d) => d.name).toList()}');
    final ex = view.dimensionByName('exercise');
    print('exercise widget: ${ex?.input?.widget}, samples count: ${ex?.samples?.length}');
    final st = view.dimensionByName('start_time');
    print('start_time dim: name=${st?.name} expr=${st?.expr} type=${st?.type}');
  } catch (e, s) {
    print('PARSE ERROR: $e');
    print(s);
  }
}
