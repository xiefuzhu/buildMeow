// Compares colour metrics under the app's dither, on one picture.
//
// Usage, from the mapart_core package root:
//   dart run tool/metric_probe.dart [source image] [mapsX] [mapsY]
//
// With no image, uses a flat pale-cyan fill. Blur is a 5x5 box, reported as
// CIE76 whatever metric did the matching. `ms` is quantization only.
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:mapart_core/mapart_core.dart';

void main(List<String> args) {
  final table = ColorTable.fromJson(
    jsonDecode(File('assets/colors/mapartcraft.colors.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final palette = Palette.select(table, '1.20');

  final RgbaImage grid;
  if (args.isEmpty) {
    grid = _solid(48, 64, const Rgb(178, 235, 240));
    stdout.writeln('source: synthetic pale cyan ${grid.width}x${grid.height}');
  } else {
    final mapsX = args.length > 1 ? int.parse(args[1]) : 1;
    final mapsY = args.length > 2 ? int.parse(args[2]) : 1;
    final decoded = img.decodeImage(File(args[0]).readAsBytesSync());
    if (decoded == null) {
      stderr.writeln('could not decode ${args[0]}');
      exitCode = 1;
      return;
    }
    grid = fitToGrid(
      _toRgba(decoded),
      mapsX * 128,
      mapsY * 128,
      mode: CropMode.cover,
      background: const Rgb(255, 255, 255),
    );
    stdout.writeln('source: ${args[0]} -> ${grid.width}x${grid.height}');
  }

  stdout.writeln(
    '${'metric'.padRight(16)}${'dither'.padLeft(8)}'
    '${'blur5'.padLeft(8)}${'span'.padLeft(7)}'
    '${'ms'.padLeft(8)}  pick',
  );
  for (final metric in ColorMetric.values) {
    for (final dither in [DitherMode.none, DitherMode.floydSteinberg]) {
      final watch = Stopwatch()..start();
      final quantized = quantize(
        source: grid,
        palette: palette,
        options: QuantizeOptions(dither: dither, metric: metric),
      );
      final quantMs = watch.elapsedMilliseconds;
      final solution = solveHeights(
        quantized: quantized,
        options: HeightSolverOptions(
          flatnessWeight: quantized.dithered ? 0 : 5,
        ),
      );
      final rendered = renderMap(
        solution: solution,
        quantized: quantized,
        palette: palette,
      );
      final blur = _blurred(grid, rendered);
      final sample = rendered.pixelAt(grid.width ~/ 2, grid.height ~/ 2);
      final ditherLabel = dither == DitherMode.none ? 'flat' : 'floyd';
      stdout.writeln(
        '${metric.name.padRight(16)}'
        '${ditherLabel.padRight(8)}'
        '${blur.toStringAsFixed(2).padLeft(8)}'
        '${solution.blockHeightSpan.toString().padLeft(7)}'
        '${quantMs.toString().padLeft(8)}'
        '  ${_hex(sample)}',
      );
    }
  }
}

RgbaImage _solid(int width, int height, Rgb color) {
  final image = RgbaImage(width, height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setRgb(x, y, color);
    }
  }
  return image;
}

String _hex(Rgb c) =>
    '#${c.r.toRadixString(16).padLeft(2, '0')}'
    '${c.g.toRadixString(16).padLeft(2, '0')}'
    '${c.b.toRadixString(16).padLeft(2, '0')}';

RgbaImage _toRgba(img.Image decoded) {
  final rgba = decoded.convert(numChannels: 4);
  final out = RgbaImage(rgba.width, rgba.height);
  for (var y = 0; y < rgba.height; y++) {
    for (var x = 0; x < rgba.width; x++) {
      final p = rgba.getPixel(x, y);
      out.setPixel(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(), p.a.toInt());
    }
  }
  return out;
}

double _blurred(RgbaImage target, RgbaImage rendered) {
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
  const radius = 2;
  final out = RgbaImage(image.width, image.height);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      var r = 0, g = 0, b = 0, n = 0;
      for (var dy = -radius; dy <= radius; dy++) {
        final sy = y + dy;
        if (sy < 0 || sy >= image.height) continue;
        for (var dx = -radius; dx <= radius; dx++) {
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
