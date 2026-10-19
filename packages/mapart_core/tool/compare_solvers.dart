// Compares the greedy solver against the flatness-aware dynamic program on the
// same images, so the default can be chosen from evidence rather than taste.
//
// Run with `dart run tool/compare_solvers.dart`.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:mapart_core/mapart_core.dart';

void main() {
  final table = ColorTable.fromJson(
    jsonDecode(
          File('assets/colors/mapartcraft.colors.json').readAsStringSync(),
        )
        as Map<String, dynamic>,
  );
  final palette = Palette.select(table, '1.20');

  final images = <String, RgbaImage>{
    'smooth vertical gradient': _verticalGradient(128, 128),
    'smooth diagonal gradient': _diagonalGradient(128, 128),
    'low-frequency photo-ish': _photoish(128, 128, grain: 6),
    'high-frequency photo-ish': _photoish(128, 128, grain: 40),
    'white noise': _noise(128, 128),
  };

  stdout.writeln(
    '${'image'.padRight(26)}${'greedy'.padLeft(22)}'
    '${'DP w=1 d=16'.padLeft(24)}${'DP w=5 d=32'.padLeft(24)}',
  );
  stdout.writeln('${''.padRight(26)}${'span  cost  bad'.padLeft(22)}'
      '${'span  cost  bad'.padLeft(24)}${'span  cost  bad'.padLeft(24)}');
  stdout.writeln('-' * 96);

  for (final entry in images.entries) {
    final quantized = quantize(source: entry.value, palette: palette);

    final greedy = solveHeights(quantized: quantized);
    final dp1 = solveHeights(
      quantized: quantized,
      options: const HeightSolverOptions(flatnessWeight: 1, freeDrift: 16),
    );
    final dp5 = solveHeights(
      quantized: quantized,
      options: const HeightSolverOptions(flatnessWeight: 5, freeDrift: 32),
    );

    String cell(HeightSolution s) {
      final bad = countMismatchedPixels(
        solution: s,
        quantized: quantized,
        palette: palette,
      );
      final span = s.maxHeight - s.minHeight;
      return '${span.toString().padLeft(5)}'
          '${s.totalCost.round().toString().padLeft(7)}'
          '${bad.toString().padLeft(5)}';
    }

    stdout.writeln(
      '${entry.key.padRight(26)}${cell(greedy).padLeft(22)}'
      '${cell(dp1).padLeft(24)}${cell(dp5).padLeft(24)}',
    );
  }

  stdout.writeln('');
  stdout.writeln('span = maxHeight - minHeight in block layers');
  stdout.writeln('cost = sum of chosen CIE76 distances, lower is more faithful');
  stdout.writeln('bad  = pixels the staircase could not reproduce exactly');
}

RgbaImage _verticalGradient(int width, int height) {
  final image = RgbaImage(width, height);
  for (var y = 0; y < height; y++) {
    final v = (255 * y / (height - 1)).round();
    for (var x = 0; x < width; x++) {
      image.setPixel(x, y, v, v, v);
    }
  }
  return image;
}

RgbaImage _diagonalGradient(int width, int height) {
  final image = RgbaImage(width, height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final v = (255 * (x + y) / (width + height - 2)).round();
      image.setPixel(x, y, v, v ~/ 2, 255 - v);
    }
  }
  return image;
}

RgbaImage _photoish(int width, int height, {required int grain}) {
  final random = math.Random(7);
  final image = RgbaImage(width, height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final base = 128 + 90 * math.sin(x / 45) * math.cos(y / 35);
      final g = grain == 0 ? 0 : random.nextInt(grain * 2 + 1) - grain;
      image.setPixel(
        x,
        y,
        (base + g).clamp(0, 255).toInt(),
        (base * 0.9 + g).clamp(0, 255).toInt(),
        (base * 0.75 + g).clamp(0, 255).toInt(),
      );
    }
  }
  return image;
}

RgbaImage _noise(int width, int height) {
  final random = math.Random(99);
  final image = RgbaImage(width, height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixel(
        x,
        y,
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
      );
    }
  }
  return image;
}
