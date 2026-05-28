import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/models/view_schema.dart';
import 'package:ledger/services/cell_codec.dart';

void main() {
  group('CellCodec.encode', () {
    test('string', () {
      expect(CellCodec.encode(DimensionType.string, 'hi'), 'hi');
      expect(CellCodec.encode(DimensionType.string, null), '');
    });

    test('number stays numeric (no leading-quote in Sheets)', () {
      expect(CellCodec.encode(DimensionType.number, 42), 42);
      expect(CellCodec.encode(DimensionType.number, 3.14), 3.14);
      // Stringy input is coerced if parseable.
      expect(CellCodec.encode(DimensionType.number, '7'), 7);
    });

    test('date as YYYY-MM-DD', () {
      expect(
        CellCodec.encode(DimensionType.date, DateTime(2026, 5, 26)),
        '2026-05-26',
      );
    });

    test('datetime as ISO 8601', () {
      final dt = DateTime.utc(2026, 5, 26, 12, 0);
      expect(
        CellCodec.encode(DimensionType.datetime, dt),
        '2026-05-26T12:00:00.000Z',
      );
    });

    test('boolean stays bool', () {
      expect(CellCodec.encode(DimensionType.boolean, true), true);
      expect(CellCodec.encode(DimensionType.boolean, false), false);
    });
  });

  group('CellCodec.decode', () {
    test('string', () {
      expect(CellCodec.decode(DimensionType.string, 'hello'), 'hello');
      expect(CellCodec.decode(DimensionType.string, ''), isNull);
      expect(CellCodec.decode(DimensionType.string, null), isNull);
    });

    test('number from string or num', () {
      expect(CellCodec.decode(DimensionType.number, '42'), 42);
      expect(CellCodec.decode(DimensionType.number, '3.14'), 3.14);
      expect(CellCodec.decode(DimensionType.number, 42), 42);
    });

    test('date', () {
      final d = CellCodec.decode(DimensionType.date, '2026-05-26') as DateTime;
      expect(d.year, 2026);
      expect(d.month, 5);
      expect(d.day, 26);
    });

    test('datetime', () {
      final d = CellCodec.decode(DimensionType.datetime, '2026-05-26T12:00:00.000Z')
          as DateTime;
      expect(d.year, 2026);
      expect(d.hour, 12);
    });

    test('boolean', () {
      expect(CellCodec.decode(DimensionType.boolean, 'true'), true);
      expect(CellCodec.decode(DimensionType.boolean, 'false'), false);
      expect(CellCodec.decode(DimensionType.boolean, 'TRUE'), true);
    });
  });
}
