// Renders the real pipeline on a picture and writes PNGs, so the result can be
// looked at rather than inferred from a mean error.
//
// Also lists the worst pixels — the ones where the rendered colour has nothing
// to do with the source — because "why is there a random colour patch" is a
// question about individual pixels and a mean hides exactly those.
//
// Usage, from the mapart_core package root:
//   dart run tool/render_png.dart <source image> [outPrefix] [mapsX] [mapsY]
//       [threshold] [dither|none] [cie76|ciede2000]
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:mapart_core/mapart_core.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: render_png.dart <image> [prefix] [mx] [my] '
        '[threshold] [dither|none]');
    exit(2);
  }
  final sourcePath = args[0];
  final prefix = args.length > 1 ? args[1] : 'out';
  final mapsX = args.length > 2 ? int.parse(args[2]) : 1;
  final mapsY = args.length > 3 ? int.parse(args[3]) : 1;
  final threshold = args.length > 4 ? double.parse(args[4]) : 8.0;
  final dither = args.length > 5 ? args[5] != 'none' : true;
  final metric = switch (args.length > 6 ? args[6] : 'cie76') {
    'ciede2000' => ColorMetric.ciede2000,
    'chroma' => ColorMetric.chromaWeighted,
    _ => ColorMetric.cie76,
  };

  final table = ColorTable.fromJson(
    jsonDecode(File('assets/colors/mapartcraft.colors.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final palette = Palette.blocks(table, '1.20');
  final versions = VersionTable.fromJson(
    jsonDecode(File('assets/colors/versions.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final plan = suggestHeightPlan(versions.latest);

  final decoded = img.decodeImage(File(sourcePath).readAsBytesSync())!;
  final grid = fitToGrid(
    _toRgbaImage(decoded),
    mapsX * 128,
    mapsY * 128,
    mode: CropMode.cover,
    background: const Rgb(255, 255, 255),
  );

  final quantized = quantize(
    source: grid,
    palette: palette,
    options: QuantizeOptions(
      dither: dither ? DitherMode.floydSteinberg : DitherMode.none,
      ditherThreshold: threshold,
      metric: metric,
      driftBudget: dither ? plan.driftBudget : null,
    ),
  );
  final solution = solveHeights(
    quantized: quantized,
    version: versions.latest,
    options: HeightSolverOptions(
      baseHeight: plan.baseHeight,
      flatnessWeight: quantized.dithered ? 0 : 5,
    ),
  );
  final rendered = renderMap(
    solution: solution,
    quantized: quantized,
    palette: palette,
  );

  // How far each rendered pixel is from the source pixel. The tail of this is
  // where "random colour patch" lives.
  final deltas = <(int x, int y, double de, Rgb src, Rgb got)>[];
  var sum = 0.0;
  var over20 = 0;
  var over40 = 0;
  for (var y = 0; y < grid.height; y++) {
    for (var x = 0; x < grid.width; x++) {
      final s = grid.pixelAt(x, y);
      final r = rendered.pixelAt(x, y);
      final de = Lab.fromRgb(s.r, s.g, s.b).distanceTo(Lab.fromRgb(r.r, r.g, r.b));
      sum += de;
      if (de > 20) over20++;
      if (de > 40) over40++;
      deltas.add((x, y, de, s, r));
    }
  }
  deltas.sort((a, b) => b.$3.compareTo(a.$3));

  // Blurred error is the figure the eye integrates, and the one the docs judge
  // variants by, so it is reported alongside the per-pixel figure.
  final blurred = _blurredMean(grid, rendered);

  stdout.writeln('grid ${grid.width}x${grid.height}  dither=$dither '
      'threshold=$threshold');
  stdout.writeln('mean dE ${(sum / deltas.length).toStringAsFixed(2)}  '
      'blurred dE ${blurred.toStringAsFixed(2)}  '
      '>20: $over20  >40: $over40  of ${deltas.length}');
  stdout.writeln('\nworst 25 pixels:');
  for (final d in deltas.take(25)) {
    stdout.writeln('  (${d.$1.toString().padLeft(3)},${d.$2.toString().padLeft(3)})'
        '  dE ${d.$3.toStringAsFixed(1).padLeft(5)}'
        '  src ${_hex(d.$4)} -> got ${_hex(d.$5)}');
  }

  // A crude cluster count: how the worst pixels are distributed in space, so a
  // scattered speckle can be told apart from a solid block of wrong colour.
  final worst = deltas.take(deltas.length ~/ 20).toList();
  final buckets = <String, int>{};
  for (final d in worst) {
    final key = '${d.$1 ~/ 32},${d.$2 ~/ 32}';
    buckets[key] = (buckets[key] ?? 0) + 1;
  }
  final top = buckets.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  stdout.writeln('\nworst 5% concentrated in 32x32 cells '
      '(x,y -> count of the ${worst.length} worst pixels):');
  for (final e in top.take(12)) {
    stdout.writeln('  ${e.key} -> ${e.value}');
  }

  File('${prefix}_target.png')
      .writeAsBytesSync(img.encodePng(_toImage(grid), level: 6));
  File('${prefix}_rendered.png')
      .writeAsBytesSync(img.encodePng(_toImage(rendered), level: 6));

  // Side by side, nearest-neighbour magnified so individual blocks are visible.
  const scale = 3;
  final side = img.Image(
    width: grid.width * 2 * scale + 8,
    height: grid.height * scale,
  );
  img.fill(side, color: img.ColorRgb8(255, 0, 255));
  for (var y = 0; y < grid.height; y++) {
    for (var x = 0; x < grid.width; x++) {
      final s = grid.pixelAt(x, y);
      final r = rendered.pixelAt(x, y);
      for (var dy = 0; dy < scale; dy++) {
        for (var dx = 0; dx < scale; dx++) {
          side.setPixelRgb(
            x * scale + dx,
            y * scale + dy,
            s.r,
            s.g,
            s.b,
          );
          side.setPixelRgb(
            (grid.width + 1) * scale + x * scale + dx,
            y * scale + dy,
            r.r,
            r.g,
            r.b,
          );
        }
      }
    }
  }
  File('${prefix}_side.png')
      .writeAsBytesSync(img.encodePng(side, level: 6));
  stdout.writeln('\nwrote ${prefix}_target.png ${prefix}_rendered.png '
      '${prefix}_side.png');
}

String _hex(Rgb c) =>
    '#${c.r.toRadixString(16).padLeft(2, '0')}'
    '${c.g.toRadixString(16).padLeft(2, '0')}'
    '${c.b.toRadixString(16).padLeft(2, '0')}';

/// Mean CIE76 error after a 3x3 box blur of both images.
double _blurredMean(RgbaImage target, RgbaImage rendered) {
  final a = _blur(target);
  final b = _blur(rendered);
  var sum = 0.0;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      final p = a.pixelAt(x, y);
      final q = b.pixelAt(x, y);
      sum += Lab.fromRgb(p.r, p.g, p.b).distanceTo(Lab.fromRgb(q.r, q.g, q.b));
    }
  }
  return sum / (a.width * a.height);
}

RgbaImage _blur(RgbaImage image) {
  final out = RgbaImage(image.width, image.height);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      var r = 0, g = 0, b = 0, n = 0;
      for (var dy = -1; dy <= 1; dy++) {
        final sy = y + dy;
        if (sy < 0 || sy >= image.height) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final sx = x + dx;
          if (sx < 0 || sx >= image.width) continue;
          final p = image.pixelAt(sx, sy);
          r += p.r;
          g += p.g;
          b += p.b;
          n++;
        }
      }
      out.setPixel(x, y, r ~/ n, g ~/ n, b ~/ n);
    }
  }
  return out;
}

img.Image _toImage(RgbaImage source) {
  final out = img.Image(width: source.width, height: source.height);
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final p = source.pixelAt(x, y);
      out.setPixelRgb(x, y, p.r, p.g, p.b);
    }
  }
  return out;
}

RgbaImage _toRgbaImage(img.Image source) {
  final out = RgbaImage(source.width, source.height);
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final p = source.getPixel(x, y);
      out.setPixel(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(), p.a.toInt());
    }
  }
  return out;
}
