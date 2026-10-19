// Times the pieces the app runs, at the sizes a user actually picks.
//
// `dart run` is JIT, which is not what ships. Compile first for a real number:
//   dart compile exe tool/time_pipeline.dart -o build/time_pipeline.exe
//   build/time_pipeline.exe
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:mapart_core/mapart_core.dart';

void main() {
  final table = ColorTable.fromJson(
    jsonDecode(File('assets/colors/mapartcraft.colors.json').readAsStringSync())
        as Map<String, dynamic>,
  ).includingGameBlocks(
    jsonDecode(File('assets/colors/block_map_colors.json').readAsStringSync())
        as Map<String, dynamic>,
    '26.1.2',
  );
  final colors = _blockColors();
  final palette = Palette.blocks(
    table,
    '1.20',
    gameVersion: '26.1.2',
    includeSupportBlocks: true,
  ).withBlockColors(colors, host: table.colors.first);
  stdout.writeln(
    'palette ${palette.length} blocks, '
    '${palette.distinctColorCount} distinct colours',
  );

  final versions = VersionTable.fromJson(
    jsonDecode(File('assets/colors/versions.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final version = versions.require('26.1.2');
  final source = _source(1920, 1080);

  for (final maps in [1, 3, 5]) {
    final side = maps * 128;
    stdout.writeln('\n${maps}x$maps ($side px), block-pixels palette');
    for (final cap in <int?>[null, 60]) {
      final sw = Stopwatch()..start();
      final grid = fitToGrid(
        source,
        side,
        side,
        mode: CropMode.cover,
        background: const Rgb(255, 255, 255),
      );
      final resize = sw.elapsedMilliseconds;
      final plan = suggestHeightPlan(version);
      final quantized = quantize(
        source: grid,
        palette: palette,
        options: QuantizeOptions(
          dither: DitherMode.floydSteinberg,
          metric: ColorMetric.chromaWeighted,
          driftBudget: plan.driftBudget,
          maxBlocks: cap,
        ),
      );
      final quant = sw.elapsedMilliseconds;
      final solution = solveHeights(
        quantized: quantized,
        version: version,
        options: HeightSolverOptions(baseHeight: plan.baseHeight),
      );
      final solve = sw.elapsedMilliseconds;
      renderMap(solution: solution, quantized: quantized, palette: palette);
      final render = sw.elapsedMilliseconds;
      stdout.writeln(
        '  cap ${(cap ?? 'none').toString().padLeft(4)}: '
        'resize ${resize}ms  quantize ${quant - resize}ms  '
        'solve ${solve - quant}ms  render ${render - solve}ms',
      );
    }
  }
}

Map<String, int> _blockColors() {
  final kept = (jsonDecode(
            File('assets/colors/kept_blocks.json').readAsStringSync(),
          )
          as List<Object?>)
      .cast<String>()
      .toSet();
  final json =
      jsonDecode(
            File('assets/colors/texture_palette_26_1_2.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final out = <String, int>{};
  for (final raw in json['blocks'] as List) {
    final block = raw as Map<String, dynamic>;
    final srgb = block['srgb'];
    if (srgb is! List || srgb.length != 3) continue;
    if (block['excluded'] != null) continue;
    final opaque = block['opaquePixels'];
    if (opaque is num && opaque < 200) continue;
    final id = block['block'] as String;
    if (!kept.contains(id)) continue;
    out[id] =
        ((srgb[0] as num).toInt() << 16) |
        ((srgb[1] as num).toInt() << 8) |
        (srgb[2] as num).toInt();
  }
  return out;
}

RgbaImage _source(int width, int height) {
  final image = RgbaImage(width, height);
  final bytes = image.bytes;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final o = (y * width + x) * 4;
      bytes[o] = (x * 255 ~/ width);
      bytes[o + 1] = (y * 255 ~/ height);
      bytes[o + 2] = (math.sin(x * 0.01) * 127 + 128).toInt();
      bytes[o + 3] = 255;
    }
  }
  return image;
}
