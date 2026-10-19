// Throwaway: how much does the drift budget cost, per pixel and after blurring,
// on the uniform out-of-gamut pale blue the quantize tests use.
import 'dart:convert';
import 'dart:io';

import 'package:mapart_core/mapart_core.dart';

void main() {
  final table = ColorTable.fromJson(
    jsonDecode(File('assets/colors/mapartcraft.colors.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final palette = Palette.blocks(table, '1.20');
  final grid = _solid(64, 64, const Rgb(200, 232, 248));

  for (final budget in <int?>[null, 4]) {
    final quantized = quantize(
      source: grid,
      palette: palette,
      options: QuantizeOptions(
        dither: DitherMode.floydSteinberg,
        driftBudget: budget,
      ),
    );
    final solution = solveHeights(
      quantized: quantized,
      options: const HeightSolverOptions(baseHeight: 0),
    );
    final rendered = renderMap(
      solution: solution,
      quantized: quantized,
      palette: palette,
    );

    var perPixel = 0.0;
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        perPixel += _d(grid.pixelAt(x, y), rendered.pixelAt(x, y));
      }
    }

    // 4x4 box average of both, which is what a viewer integrates at map scale.
    var blurred = 0.0;
    for (var y = 0; y < 64; y += 4) {
      for (var x = 0; x < 64; x += 4) {
        blurred += _d(_mean(grid, x, y), _mean(rendered, x, y));
      }
    }

    stdout.writeln(
      'budget ${budget ?? 'none'}: per-pixel '
      '${(perPixel / (64 * 64)).toStringAsFixed(2)}  '
      'blurred ${(blurred / (16 * 16)).toStringAsFixed(2)}  '
      'span ${solution.maxHeight - solution.minHeight}',
    );
  }
}

Rgb _mean(RgbaImage image, int x0, int y0) {
  var r = 0, g = 0, b = 0;
  for (var y = y0; y < y0 + 4; y++) {
    for (var x = x0; x < x0 + 4; x++) {
      final p = image.pixelAt(x, y);
      r += p.r;
      g += p.g;
      b += p.b;
    }
  }
  return Rgb(r ~/ 16, g ~/ 16, b ~/ 16);
}

double _d(Rgb a, Rgb b) => Lab.fromRgb(a.r, a.g, a.b).distanceTo(
  Lab.fromRgb(b.r, b.g, b.b),
);

RgbaImage _solid(int width, int height, Rgb color) {
  final out = RgbaImage(width, height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      out.setRgb(x, y, color);
    }
  }
  return out;
}
