import 'dart:typed_data';

import 'package:mapart_core/mapart_core.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'blueprint_layout.dart';

/// Everything the sheets need that is not the plan itself.
class BlueprintPdfRequest {
  const BlueprintPdfRequest({
    required this.plan,
    required this.fontRegular,
    required this.fontBold,
    this.sourceName,
    this.generatedAt,
    this.summary,
  });

  final MapPlan plan;

  /// The subsetted Noto Sans SC, as TrueType bytes. The `pdf` package cannot use
  /// a system font and cannot read a variable font, which is why the app ships
  /// two instanced subsets rather than asking for one.
  final Uint8List fontRegular;
  final Uint8List fontBold;

  final String? sourceName;
  final DateTime? generatedAt;
  final BuildSummary? summary;
}

/// Builds an overview, a diagram per map with paginated legends, and the
/// shopping list.
///
/// Drawn as vectors rather than as images of the picture: a cell is a filled
/// rectangle and the lines and labels are drawn on top, so the sheet stays crisp
/// at any zoom and the text stays selectable. Adjacent cells of the same colour
/// are merged into one rectangle first — a run-length pass over each row, which
/// turns a flat region from thousands of rectangles into a handful.
///
/// Pure Dart, so this can run in an isolate: the two font subsets are passed in
/// rather than loaded, because `rootBundle` is not available in a background
/// isolate.
Future<Uint8List> buildBlueprintPdf(BlueprintPdfRequest request) async {
  final plan = request.plan;
  final tiles = blueprintTiles(plan);
  final regular = pw.Font.ttf(ByteData.sublistView(request.fontRegular));
  final bold = pw.Font.ttf(ByteData.sublistView(request.fontBold));
  final document = pw.Document(title: '建喵! 图纸', author: '建喵!', creator: '建喵!');

  document.addPage(_overviewPage(plan, tiles, request, regular, bold));
  for (final tile in tiles) {
    document.addPage(_tilePage(plan, tile, request, regular, bold));
  }
  document.addPage(_materialsPage(plan, request, regular, bold));

  return Uint8List.fromList(await document.save());
}

/// The whole picture at a glance, fitted between the actual header and notes.
pw.Page _overviewPage(
  MapPlan plan,
  List<BlueprintTile> tiles,
  BlueprintPdfRequest request,
  pw.Font regular,
  pw.Font bold,
) {
  const margin = 28.0;
  return pw.Page(
    pageFormat: PdfPageFormat.a4.landscape,
    margin: const pw.EdgeInsets.all(margin),
    build: (context) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('建喵! 地图画图纸', style: pw.TextStyle(font: bold, fontSize: 16)),
        pw.SizedBox(height: 2),
        pw.Text(
          blueprintSubtitle(plan, sourceName: request.sourceName),
          style: pw.TextStyle(font: regular, fontSize: 8),
        ),
        pw.SizedBox(height: 10),
        pw.Expanded(
          child: pw.LayoutBuilder(
            builder: (context, constraints) {
              final cell = _min(
                3.0,
                constraints!.maxWidth / plan.width,
                constraints.maxHeight / plan.height,
              );
              return pw.Align(
                alignment: pw.Alignment.centerLeft,
                child: pw.CustomPaint(
                  size: PdfPoint(plan.width * cell, plan.height * cell),
                  painter: (canvas, size) =>
                      _paintGrid(canvas, plan, null, cell, showChunks: false),
                ),
              );
            },
          ),
        ),
        pw.SizedBox(height: 8),
        pw.Text(
          '每张地图 ${tiles.length} 分之一,共 ${tiles.length} 张。'
          '下面每张地图各有图纸,格子更大,长图例会续页。',
          style: pw.TextStyle(font: regular, fontSize: 8),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          blueprintReferenceNote(plan),
          style: pw.TextStyle(font: regular, fontSize: 8),
        ),
        pw.Text(
          blueprintAlignmentNote(plan),
          style: pw.TextStyle(font: regular, fontSize: 8),
        ),
      ],
    ),
  );
}

/// One map, at a size where a block is a visible square.
pw.MultiPage _tilePage(
  MapPlan plan,
  BlueprintTile tile,
  BlueprintPdfRequest request,
  pw.Font regular,
  pw.Font bold,
) {
  const margin = 24.0;
  final page = PdfPageFormat.a4;
  final width = page.width - 2 * margin;
  final cell = _min(6.0, width / tile.width, width / tile.height);

  return pw.MultiPage(
    pageFormat: page,
    margin: const pw.EdgeInsets.all(margin),
    theme: pw.ThemeData.withFont(base: regular, bold: bold),
    maxPages: 100,
    header: (context) => pw.Column(
      mainAxisSize: pw.MainAxisSize.min,
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          '${tileLabel(tile)} · 建喵! 图纸',
          style: pw.TextStyle(font: bold, fontSize: 14),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          '格子 ${tile.width} x ${tile.height} · 每个小格一个方块 · '
          '每 16 格一条线(区块边界)',
          style: pw.TextStyle(font: regular, fontSize: 8),
        ),
        pw.SizedBox(height: 8),
      ],
    ),
    footer: (context) => pw.Column(
      mainAxisSize: pw.MainAxisSize.min,
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(height: 8),
        pw.Text(
          !plan.requiresReferenceRow || tile.hasReferenceRow
              ? blueprintReferenceNote(plan)
              : '本张地图北边是上一张地图,不需要额外建参照行。',
          style: pw.TextStyle(font: regular, fontSize: 8),
        ),
        pw.Text(
          blueprintAlignmentNote(plan),
          style: pw.TextStyle(font: regular, fontSize: 8),
        ),
      ],
    ),
    build: (context) => [
      pw.SizedBox(
        width: tile.width * cell,
        height: tile.height * cell,
        child: pw.CustomPaint(
          size: PdfPoint(tile.width * cell, tile.height * cell),
          painter: (canvas, size) =>
              _paintGrid(canvas, plan, tile, cell, showChunks: true),
        ),
      ),
      pw.SizedBox(height: 8),
      ..._legend(plan, tile, regular, bold),
    ],
  );
}

/// The blocks this map needs, with their three shades.
List<pw.Widget> _legend(
  MapPlan plan,
  BlueprintTile tile,
  pw.Font regular,
  pw.Font bold,
) {
  // Separate rows let MultiPage carry a long legend onto following pages.
  const perRow = 3;
  final rows = <pw.Widget>[];
  for (var i = 0; i < tile.legend.length; i += perRow) {
    final slice = tile.legend.skip(i).take(perRow).toList();
    rows.add(
      pw.Row(
        children: [
          for (final entry in slice)
            pw.Expanded(
              child: pw.Row(
                children: [
                  _swatch(entry.block),
                  pw.SizedBox(width: 4),
                  pw.Expanded(
                    child: pw.Text(
                      '${entry.block.nameZh} ${entry.count}',
                      style: pw.TextStyle(font: regular, fontSize: 7),
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    rows.add(pw.SizedBox(height: 3));
  }
  return [
    pw.Text(
      '本张画面用料 ${tile.blocks} 个 · ${tile.legend.length} 种',
      style: pw.TextStyle(font: bold, fontSize: 8),
    ),
    pw.SizedBox(height: 3),
    ...rows,
  ];
}

/// The three shades of a block as a small strip, which is what the map shows.
pw.Widget _swatch(PlanBlock block) => pw.SizedBox(
  width: 16,
  height: 8,
  child: pw.Row(
    children: [
      for (final tier in ShadeTier.staircase)
        pw.Expanded(child: pw.Container(color: _pdfColor(block.tone(tier)))),
    ],
  ),
);

/// The shopping list for the whole picture.
pw.MultiPage _materialsPage(
  MapPlan plan,
  BlueprintPdfRequest request,
  pw.Font regular,
  pw.Font bold,
) {
  final summary =
      request.summary ??
      BuildSummary.fromPlan(plan, includeReferenceRow: false);
  final totals = summary.totals;
  final lines = summary.materials;

  return pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    maxPages: 100,
    theme: pw.ThemeData.withFont(base: regular, bold: bold),
    margin: const pw.EdgeInsets.all(24),
    build: (context) => [
      pw.Text('材料清单', style: pw.TextStyle(font: bold, fontSize: 14)),
      pw.SizedBox(height: 2),
      pw.Text(
        '共 ${totals.blocks} 个方块 · ${totals.kinds} 种 · '
        '折合 ${totals.stacks} 组 + ${totals.rest} 个 '
        '(${totals.stackSlots} 格物品栏)',
        style: pw.TextStyle(font: regular, fontSize: 9),
      ),
      pw.SizedBox(height: 10),
      pw.TableHelper.fromTextArray(
        headers: const ['方块', '中文名', '数量', '组', '剩余'],
        data: [
          for (final line in lines)
            [
              line.block.blockState,
              line.block.nameZh,
              '${line.count}',
              '${line.stacks}',
              '${line.rest}',
            ],
        ],
        headerStyle: pw.TextStyle(font: bold, fontSize: 8),
        cellStyle: pw.TextStyle(font: regular, fontSize: 8),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        columnWidths: const {
          0: pw.FlexColumnWidth(2.4),
          1: pw.FlexColumnWidth(1.8),
          2: pw.FlexColumnWidth(1),
          3: pw.FlexColumnWidth(0.7),
          4: pw.FlexColumnWidth(0.7),
        },
        headerDecoration: const pw.BoxDecoration(
          color: PdfColor.fromInt(0xFFEEEEEE),
        ),
      ),
    ],
  );
}

/// Draws the grid, one merged rectangle per run of equal colour.
///
/// [tile] is null for the whole picture. Chunk lines are drawn only where the
/// sheet is big enough for them to mean something.
void _paintGrid(
  PdfGraphics canvas,
  MapPlan plan,
  BlueprintTile? tile,
  double cell, {
  required bool showChunks,
}) {
  final x0 = tile?.x0 ?? 0;
  final y0 = tile?.y0 ?? 0;
  final x1 = tile?.x1 ?? plan.width;
  final y1 = tile?.y1 ?? plan.height;
  final height = (y1 - y0) * cell;

  for (var y = y0; y < y1; y++) {
    // PDF's origin is the bottom left, the plan's is the top left, so the row's
    // y is flipped once here rather than at every rectangle.
    final top = height - (y - y0 + 1) * cell;
    var runStart = x0;
    var runColor = plan.colorAt(x0, y);
    for (var x = x0 + 1; x <= x1; x++) {
      final color = x == x1 ? null : plan.colorAt(x, y);
      if (color == runColor) continue;
      canvas
        ..setFillColor(_pdfColor(runColor))
        ..drawRect((runStart - x0) * cell, top, (x - runStart) * cell, cell)
        ..fillPath();
      runStart = x;
      if (color != null) runColor = color;
    }
  }

  if (!showChunks) return;
  canvas
    ..setStrokeColor(const PdfColor.fromInt(0xFF000000))
    ..setLineWidth(0.4);
  for (var x = x0; x <= x1; x += 16) {
    canvas.drawLine((x - x0) * cell, 0, (x - x0) * cell, height);
  }
  for (var y = y0; y <= y1; y += 16) {
    final top = height - (y - y0) * cell;
    canvas.drawLine(0, top, (x1 - x0) * cell, top);
  }
  canvas.strokePath();
}

PdfColor _pdfColor(Rgb rgb) => PdfColor(rgb.r / 255, rgb.g / 255, rgb.b / 255);

double _min(double cap, double byWidth, double byHeight) =>
    [cap, byWidth, byHeight].reduce((a, b) => a < b ? a : b);
