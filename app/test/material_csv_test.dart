import 'dart:convert';
import 'dart:typed_data';

import 'package:build_meow/src/data/material_csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapart_core/mapart_core.dart';

import 'plan_support.dart';

/// The shopping list as a spreadsheet.
///
/// The two things that have to be right are the byte order mark — without it
/// Excel on Windows reads the Chinese names as the system code page and shows
/// mojibake, which is the one file this app exists to produce — and that the
/// numbers are the build's own rather than a second, drifting tally.
void main() {
  late MapPlan plan;

  setUpAll(() {
    plan = buildTestResult().plan;
  });

  /// The file's text, with the BOM stripped so the rows can be compared.
  List<String> rows(Uint8List bytes) =>
      utf8.decode(bytes.sublist(3)).split('\r\n');

  test('the bytes start with a UTF-8 byte order mark', () {
    final bytes = materialCsvBytes(plan);

    expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
  });

  test('the header is the columns a person shopping needs', () {
    final lines = rows(materialCsvBytes(plan));

    expect(lines.first, '方块ID,方块状态,中文名,英文名,数量,组,剩余');
  });

  test('there is one row per block, in the plan order, with its count', () {
    final lines = rows(materialCsvBytes(plan));

    for (var i = 0; i < plan.blocks.length; i++) {
      final block = plan.blocks[i];
      final line = MaterialLine(block: block, count: plan.counts[i]);
      final expected = [
        block.blockId,
        block.blockState,
        block.nameZh,
        block.nameEn,
        '${line.count}',
        '${line.stacks}',
        '${line.rest}',
      ].join(',');
      expect(lines[i + 1], expected, reason: block.blockId);
    }
  });

  test('the last row totals the whole build', () {
    final lines = rows(materialCsvBytes(plan));
    final totals = materialTotals(plan);
    final summary = lines.last;

    expect(summary, startsWith('合计'));
    expect(summary, contains('${totals.blocks}'));
    expect(summary, contains('${totals.stacks}'));
    expect(summary, contains('${totals.rest}'));
    // And it is set off from the rows by a blank line.
    expect(lines[lines.length - 2], isEmpty);
  });

  test('a source name with a comma is quoted so the columns stay aligned', () {
    final bytes = materialCsvBytes(plan, sourceName: 'cat, sleeping.png');
    final lines = rows(bytes);

    expect(lines.last, '原图,"cat, sleeping.png",,,,,');
    // The summary is still there, one line above the source.
    expect(lines[lines.length - 2], startsWith('合计'));
  });

  test('every data row has exactly the header columns', () {
    // A block state like `minecraft:oak_log[axis=y]` is one field, and a name
    // with a comma must be quoted, or a spreadsheet silently shifts the row.
    final lines = rows(materialCsvBytes(plan));
    for (final line in lines.skip(1)) {
      if (line.isEmpty) continue;
      expect(line.split(',').length, 7, reason: line);
    }
  });
}
