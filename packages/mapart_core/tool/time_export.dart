// Times the export path: the solve, the structure, and both schematic writers,
// at the sizes a user actually picks.
//
// The numbers go in the README. `dart run` is JIT, which is not what ships;
// compile first for a real figure:
//   dart compile exe tool/time_export.dart -o build/time_export.exe
//   build/time_export.exe
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
  final names = BlockNames.fromJson(
    jsonDecode(File('assets/lang/zh_cn_blocks.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final versions = VersionTable.fromJson(
    jsonDecode(File('assets/colors/versions.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final version = versions.require(VersionTable.defaultVersionId);
  final plan = suggestHeightPlan(version);
  final source = _source(1920, 1080);

  // The staircase palette: the map-colour one, which is what produces heights
  // worth exporting.
  final mapPalette = Palette.select(table, version.blockSetAlias);

  for (final maps in [1, 3, 5]) {
    final side = maps * 128;
    stdout.writeln('\n${maps}x$maps ($side px), map-colour palette');
    final sw = Stopwatch()..start();

    final grid = fitToGrid(
      source,
      side,
      side,
      mode: CropMode.cover,
      background: const Rgb(255, 255, 255),
    );
    final resize = sw.elapsedMilliseconds;
    final quantized = quantize(
      source: grid,
      palette: mapPalette,
      options: QuantizeOptions(
        dither: DitherMode.floydSteinberg,
        metric: ColorMetric.chromaWeighted,
        driftBudget: plan.driftBudget,
        maxBlocks: 60,
      ),
    );
    final quantizeMs = sw.elapsedMilliseconds;
    final solution = solveHeights(
      quantized: quantized,
      version: version,
      options: HeightSolverOptions(baseHeight: plan.baseHeight),
    );
    final solve = sw.elapsedMilliseconds;
    final built = buildMapPlan(
      solution: solution,
      quantized: quantized,
      palette: mapPalette,
      version: version,
      names: names,
    );
    final planMs = sw.elapsedMilliseconds;
    renderPlanMap(plan: built);
    final render = sw.elapsedMilliseconds;

    stdout.writeln(
      '  solve:  resize ${resize}ms  quantize ${quantizeMs - resize}ms  '
      'heights ${solve - quantizeMs}ms  plan ${planMs - solve}ms  '
      'render ${render - planMs}ms  (total ${render}ms)',
    );

    for (final shape in ExportShape.values) {
      final structure = buildStructure(built, shape: shape);
      final build = sw.elapsedMilliseconds;
      final litematic = writeLitematic(
        structure,
        dataVersion: version.dataVersion,
        metadata: const LitematicMetadata(name: 'timing', author: '建喵!'),
      );
      final writeLt = sw.elapsedMilliseconds;
      readLitematic(litematic);
      final readLt = sw.elapsedMilliseconds;
      final schem = writeSpongeSchematic(
        structure,
        dataVersion: version.dataVersion,
      );
      final writeSchem = sw.elapsedMilliseconds;
      readSpongeSchematic(schem);
      final readSchem = sw.elapsedMilliseconds;

      stdout.writeln(
        '  ${shape.name.padRight(7)}: '
        'structure ${build - render}ms  '
        '.litematic ${writeLt - build}ms/${_kb(litematic.length)}  '
        'read back ${readLt - writeLt}ms  '
        '.schem ${writeSchem - readLt}ms/${_kb(schem.length)}  '
        'read back ${readSchem - writeSchem}ms  '
        'blocks ${structure.nonAirBlocks}',
      );
    }
  }
}

String _kb(int bytes) => '${(bytes / 1024).toStringAsFixed(0)}KB';

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
