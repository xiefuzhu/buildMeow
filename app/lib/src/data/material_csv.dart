import 'dart:convert';
import 'dart:typed_data';

import 'package:mapart_core/mapart_core.dart';

/// The shopping list as a spreadsheet.
///
/// Written for a person holding a shulker box, not for a parser: one row per
/// block, the count and the same count as stacks and loose blocks, because the
/// number you need at the crafting table is the second one.
String materialCsv(MapPlan plan, {String? sourceName, BuildSummary? summary}) {
  final lines = <String>[
    '方块ID,方块状态,中文名,英文名,数量,组,剩余',
    for (var i = 0; i < plan.blocks.length; i++)
      _row(plan.blocks[i], summary?.counts[i] ?? plan.counts[i]),
    '',
    _summary(plan, summary?.totalBlocks ?? plan.totalBlocks),
  ];
  if (sourceName != null && sourceName.isNotEmpty) {
    lines.add('原图,${_quote(sourceName)},,,,,');
  }
  return lines.join('\r\n');
}

/// The same, as bytes with a UTF-8 byte order mark.
///
/// The BOM is not decoration: Excel on Windows reads a CSV without one as the
/// system code page and turns every Chinese name into mojibake, which is exactly
/// the file this app exists to produce.
Uint8List materialCsvBytes(
  MapPlan plan, {
  String? sourceName,
  BuildSummary? summary,
}) {
  final bytes = utf8.encode(
    materialCsv(plan, sourceName: sourceName, summary: summary),
  );
  return Uint8List.fromList([0xEF, 0xBB, 0xBF, ...bytes]);
}

String _row(PlanBlock block, int count) {
  final line = MaterialLine(block: block, count: count);
  return [
    _quote(block.blockId),
    _quote(block.blockState),
    _quote(block.nameZh),
    _quote(block.nameEn),
    '$count',
    '${line.stacks}',
    '${line.rest}',
  ].join(',');
}

String _summary(MapPlan plan, int total) {
  return [
    '合计',
    '',
    '',
    '',
    '$total',
    '${total ~/ 64}',
    '${total % 64}',
  ].join(',');
}

/// Wraps a field in quotes when it contains anything a comma-separated file
/// treats specially.
String _quote(String value) =>
    value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r')
    ? '"${value.replaceAll('"', '""')}"'
    : value;
