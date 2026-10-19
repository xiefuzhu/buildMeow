import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:mapart_core/mapart_core.dart';
import 'package:material_ui/material_ui.dart';

import 'blueprint_layout.dart';

/// The font family the blueprint sheets are drawn with.
///
/// The two subsetted Noto Sans SC files in `assets/fonts`, declared under both
/// `fonts:` and `assets:` in the pubspec: the first is what `TextStyle` uses
/// here, the second is what `rootBundle` hands to the PDF builder. One family
/// rather than the system's, so the PNG and the PDF cannot look different.
const String kBlueprintFontFamily = 'NotoSansSC';

/// What a PNG sheet needs.
class BlueprintPngRequest {
  const BlueprintPngRequest({
    required this.plan,
    required this.cell,
    this.tile,
    this.sourceName,
    this.thumbnail = false,
  });

  final MapPlan plan;

  /// Pixels per block. Eight puts a map at 1024 px on a side, which is sharp
  /// enough to read a dithered region and small enough to email.
  final int cell;

  /// The tile to draw, or null for the whole picture.
  final BlueprintTile? tile;

  final String? sourceName;
  final bool thumbnail;
}

/// Renders one sheet as a PNG.
///
/// Runs on the UI isolate — `ui.PictureRecorder` is part of the engine — which
/// is why the export builds its PNGs before handing the rest to an isolate.
Future<Uint8List> buildBlueprintPng(BlueprintPngRequest request) async {
  final plan = request.plan;
  final tile = request.tile;
  final cell = request.cell;

  final x0 = tile?.x0 ?? 0;
  final y0 = tile?.y0 ?? 0;
  final x1 = tile?.x1 ?? plan.width;
  final y1 = tile?.y1 ?? plan.height;
  final columns = x1 - x0;
  final rows = y1 - y0;

  const margin = 24.0;
  const gutter = 34.0;
  const header = 56.0;
  const legendLine = 20.0;
  final legendLines = tile == null
      ? 0
      : math.max(1, (tile.legend.length / 3).ceil());
  final footer = 46.0;

  final gridWidth = columns * cell.toDouble();
  final gridHeight = rows * cell.toDouble();
  final width = margin * 2 + gutter + gridWidth;
  final height =
      margin * 2 + header + gridHeight + legendLines * legendLine + footer;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final origin = Offset(margin + gutter, margin + header);

  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = const Color(0xFFFFFFFF),
  );

  _drawHeader(canvas, request, tile, margin, width);
  _drawGrid(canvas, plan, tile, origin, cell);
  _drawRulers(canvas, plan, tile, origin, cell, margin, gutter, gridHeight);
  if (tile != null) {
    _drawLegend(
      canvas,
      tile,
      origin + Offset(0, gridHeight + 6),
      width - margin * 2 - gutter,
      legendLine,
    );
  }
  _drawFooter(
    canvas,
    plan,
    tile,
    Offset(
      margin + gutter,
      origin.dy + gridHeight + legendLines * legendLine + 6,
    ),
    width - margin * 2 - gutter,
  );

  final picture = recorder.endRecording();
  final image = await picture.toImage(width.ceil(), height.ceil());
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (data == null) {
    throw StateError('the engine produced no PNG for the blueprint sheet');
  }
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

void _drawHeader(
  Canvas canvas,
  BlueprintPngRequest request,
  BlueprintTile? tile,
  double margin,
  double width,
) {
  final title = tile == null
      ? (request.thumbnail ? '建喵! 图纸总览（缩略）' : '建喵! 图纸总览')
      : '${tileLabel(tile)} · 建喵! 图纸';
  _text(
    canvas,
    title,
    Offset(margin, margin - 4),
    size: 20,
    weight: FontWeight.w700,
  );
  _text(
    canvas,
    blueprintSubtitle(request.plan, sourceName: request.sourceName),
    Offset(margin, margin + 24),
    size: 11,
  );
  if (tile != null) {
    _text(
      canvas,
      '每个小格一个方块 · 每 16 格一条区块线',
      Offset(margin, margin + 40),
      size: 10,
    );
  }
}

void _drawGrid(
  Canvas canvas,
  MapPlan plan,
  BlueprintTile? tile,
  Offset origin,
  int cell,
) {
  final x0 = tile?.x0 ?? 0;
  final y0 = tile?.y0 ?? 0;
  final x1 = tile?.x1 ?? plan.width;
  final y1 = tile?.y1 ?? plan.height;
  final paint = Paint()..style = PaintingStyle.fill;

  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      paint.color = _color(plan.colorAt(x, y));
      canvas.drawRect(
        Rect.fromLTWH(
          origin.dx + (x - x0) * cell.toDouble(),
          origin.dy + (y - y0) * cell.toDouble(),
          cell.toDouble(),
          cell.toDouble(),
        ),
        paint,
      );
    }
  }

  final grid = Paint()
    ..color = const Color(0x66000000)
    ..strokeWidth = 0.6;
  for (var x = x0; x <= x1; x += 16) {
    final dx = origin.dx + (x - x0) * cell.toDouble();
    canvas.drawLine(
      Offset(dx, origin.dy),
      Offset(dx, origin.dy + (y1 - y0) * cell.toDouble()),
      grid,
    );
  }
  for (var y = y0; y <= y1; y += 16) {
    final dy = origin.dy + (y - y0) * cell.toDouble();
    canvas.drawLine(
      Offset(origin.dx, dy),
      Offset(origin.dx + (x1 - x0) * cell.toDouble(), dy),
      grid,
    );
  }
}

/// The coordinate labels along the top and the left.
///
/// The numbers are the picture's own cell coordinates, which is what the app's
/// blueprint viewer shows when a cell is tapped, so a printed sheet and the
/// screen agree about where cell 64 is.
void _drawRulers(
  Canvas canvas,
  MapPlan plan,
  BlueprintTile? tile,
  Offset origin,
  int cell,
  double margin,
  double gutter,
  double gridHeight,
) {
  final x0 = tile?.x0 ?? 0;
  final y0 = tile?.y0 ?? 0;
  final x1 = tile?.x1 ?? plan.width;
  final y1 = tile?.y1 ?? plan.height;

  for (var x = x0; x <= x1; x += 16) {
    if (x == x1) continue;
    _text(
      canvas,
      '$x',
      Offset(origin.dx + (x - x0) * cell.toDouble() + 1, origin.dy - 13),
      size: 9,
    );
  }
  for (var y = y0; y <= y1; y += 16) {
    if (y == y1) continue;
    _text(
      canvas,
      '$y',
      Offset(margin + 2, origin.dy + (y - y0) * cell.toDouble() + 1),
      size: 9,
    );
  }
  _text(canvas, 'x', Offset(margin + 2, origin.dy - 13), size: 9);
  _text(
    canvas,
    'z',
    Offset(margin + gutter - 12, origin.dy + gridHeight + 2),
    size: 9,
  );
}

void _drawLegend(
  Canvas canvas,
  BlueprintTile tile,
  Offset at,
  double width,
  double lineHeight,
) {
  const perRow = 3;
  final columnWidth = width / perRow;
  for (var i = 0; i < tile.legend.length; i++) {
    final entry = tile.legend[i];
    final column = i % perRow;
    final row = i ~/ perRow;
    final left = at.dx + column * columnWidth;
    final top = at.dy + row * lineHeight;
    _swatch(canvas, entry.block, Offset(left, top + 3));
    _text(
      canvas,
      '${entry.block.nameZh} ${entry.count}',
      Offset(left + 22, top + 2),
      size: 10,
    );
  }
}

void _drawFooter(
  Canvas canvas,
  MapPlan plan,
  BlueprintTile? tile,
  Offset at,
  double width,
) {
  _text(
    canvas,
    tile == null
        ? '共 ${plan.mapsX} x ${plan.mapsY} 张地图'
        : '本张用料 ${tile.blocks} 个 · ${tile.legend.length} 种',
    at,
    size: 10,
  );
  _text(
    canvas,
    tile != null && !tile.hasReferenceRow
        ? '本张地图北边是上一张地图,不需要额外建参照行。'
        : blueprintReferenceNote(plan),
    at + const Offset(0, 15),
    size: 9,
  );
  _text(
    canvas,
    blueprintAlignmentNote(plan),
    at + const Offset(0, 29),
    size: 9,
  );
}

void _swatch(Canvas canvas, PlanBlock block, Offset at) {
  const size = 16.0;
  var left = at.dx;
  for (final tier in ShadeTier.staircase) {
    canvas.drawRect(
      Rect.fromLTWH(left, at.dy, size / 3, size / 2),
      Paint()..color = _color(block.tone(tier)),
    );
    left += size / 3;
  }
}

void _text(
  Canvas canvas,
  String value,
  Offset at, {
  required double size,
  FontWeight weight = FontWeight.w400,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: value,
      style: TextStyle(
        fontFamily: kBlueprintFontFamily,
        fontSize: size,
        fontWeight: weight,
        color: const Color(0xFF000000),
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, at);
  painter.dispose();
}

Color _color(Rgb rgb) => Color.fromARGB(255, rgb.r, rgb.g, rgb.b);
