// Records how long the pipeline takes at the sizes a user will actually pick.
//
// Run with `dart run tool/benchmark.dart` from the mapart_core package root.
// These are JIT numbers; `dart compile exe` would be considerably faster, and
// that is what the app ships. Treat them as an upper bound.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:mapart_core/mapart_core.dart';

void main() {
  final root = Directory.current;
  final table = ColorTable.fromJson(
    jsonDecode(
          File('${root.path}/assets/colors/mapartcraft.colors.json')
              .readAsStringSync(),
        )
        as Map<String, dynamic>,
  );
  final palette = Palette.select(table, '1.20');
  final versions = VersionTable.fromJson(
    jsonDecode(
          File('${root.path}/assets/colors/versions.json').readAsStringSync(),
        )
        as Map<String, dynamic>,
  );
  final version = versions.latest;

  stdout.writeln('palette: ${palette.length} colours, '
      '${palette.unavailableColorIndices.length} unavailable');
  stdout.writeln('');

  // A photographic-ish source: smooth gradients plus noise, so the resampler
  // and the colour matcher both do real work.
  final source = _sourceImage(2000, 2000);

  for (final (mapsX, mapsY) in <(int, int)>[
    (1, 1),
    (2, 2),
    (3, 3),
    (5, 5),
  ]) {
    stdout.writeln('${mapsX}x$mapsY maps (${mapsX * 128}x${mapsY * 128} px)');
    for (final dither in DitherMode.values) {
      _measure(source, mapsX, mapsY, dither, version, palette);
    }
    stdout.writeln('');
  }

  _benchmarkFlatness(palette, version);
}

void _measure(
  RgbaImage source,
  int mapsX,
  int mapsY,
  DitherMode dither,
  MinecraftVersion version,
  Palette palette,
) {
  final label = switch (dither) {
    DitherMode.none => 'plain      ',
    DitherMode.floydSteinberg => 'floyd      ',
    DitherMode.halftone => 'halftone   ',
  };
  final sw = Stopwatch()..start();

  final grid = fitToGrid(
    source,
    mapsX * 128,
    mapsY * 128,
    mode: CropMode.cover,
    background: const Rgb(255, 255, 255),
  );
  final afterResize = sw.elapsedMilliseconds;

  final plan = suggestHeightPlan(version);
  final quantized = quantize(
    source: grid,
    palette: palette,
    options: QuantizeOptions(
      dither: dither,
      driftBudget: dither == DitherMode.none ? null : plan.driftBudget,
    ),
  );
  final afterQuantize = sw.elapsedMilliseconds;

  final solution = solveHeights(
    quantized: quantized,
    version: version,
    options: HeightSolverOptions(baseHeight: plan.baseHeight),
  );
  final afterSolve = sw.elapsedMilliseconds;

  final rendered = renderMap(
    solution: solution,
    quantized: quantized,
    palette: palette,
  );
  final afterRender = sw.elapsedMilliseconds;

  final mismatched = countMismatchedPixels(
    solution: solution,
    quantized: quantized,
    palette: palette,
  );

  stdout.writeln(
    '    $label total ${afterRender}ms  '
    '(resize $afterResize / quantize ${afterQuantize - afterResize} / '
    'solve ${afterSolve - afterQuantize} / render ${afterRender - afterSolve})',
  );
  stdout.writeln(
    '        Y ${solution.minHeight}..${solution.maxHeight} '
    '(${solution.blockHeightSpan} layers, reference row Y '
    '${solution.referenceRowHeight}), mismatched $mismatched, '
        '${rendered.width}x${rendered.height}',
  );
  if (solution.warnings.isNotEmpty) {
    for (final warning in solution.warnings) {
      stdout.writeln('        ! $warning');
    }
  }
}

void _benchmarkFlatness(
  Palette palette,
  MinecraftVersion version,
) {
  // The dynamic-programming path only runs when flatness pressure is on, and it
  // is the only part of the pipeline whose cost depends on the search window.
  stdout.writeln('flatness solver (128x128):');
  final grid = fitToGrid(
    _sourceImage(1000, 1000),
    128,
    128,
    mode: CropMode.cover,
    background: const Rgb(255, 255, 255),
  );
  final quantized = quantize(source: grid, palette: palette);

  for (final freeDrift in <int>[8, 32, 128]) {
    final sw = Stopwatch()..start();
    final solution = solveHeights(
      quantized: quantized,
      version: version,
      options: HeightSolverOptions(
        baseHeight: 64,
        flatnessWeight: 5,
        freeDrift: freeDrift,
      ),
    );
    stdout.writeln(
      '    freeDrift $freeDrift -> ${sw.elapsedMilliseconds}ms, '
      'range ${solution.maxHeight - solution.minHeight}, '
      'window hits ${solution.windowHits}',
    );
  }
}

RgbaImage _sourceImage(int width, int height) {
  final random = math.Random(20261012);
  final image = RgbaImage(width, height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final base = 128 + 100 * math.sin(x / 90) * math.cos(y / 70);
      final grain = random.nextInt(31) - 15;
      image.setPixel(
        x,
        y,
        (base + grain).clamp(0, 255).toInt(),
        (base * 0.85 + grain).clamp(0, 255).toInt(),
        (base * 0.7 + grain).clamp(0, 255).toInt(),
      );
    }
  }
  return image;
}
