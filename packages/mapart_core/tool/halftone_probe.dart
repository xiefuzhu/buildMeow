// Compares plain, Floyd-Steinberg and the same-shade halftone on one picture.
//
// Usage, from the mapart_core package root:
//   dart run tool/halftone_probe.dart [source image] [mapsX] [mapsY]
//
// With no image, runs the synthetic pale-cyan fill the halftone is for.
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
  final threshold = args.length > 3 ? double.parse(args[3]) : 8.0;

  final RgbaImage grid;
  if (args.isEmpty) {
    grid = solidHair(48, 64);
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
  stdout.writeln('threshold $threshold, metric chroma-weighted');
  stdout.writeln(
    '${'variant'.padRight(16)}${'px'.padLeft(8)}'
    '${'blur3'.padLeft(8)}${'blur5'.padLeft(8)}'
    '${'span'.padLeft(7)}${'colours'.padLeft(9)}',
  );

  for (final mode in DitherMode.values) {
    final quantized = quantize(
      source: grid,
      palette: palette,
      options: QuantizeOptions(
        dither: mode,
        metric: ColorMetric.chromaWeighted,
        ditherThreshold: threshold,
      ),
    );
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
    final blur3 = _errors(grid, rendered, 1);
    final blur5 = _errors(grid, rendered, 2);
    final colours = <int>{};
    for (var y = 0; y < rendered.height; y++) {
      for (var x = 0; x < rendered.width; x++) {
        final c = rendered.pixelAt(x, y);
        colours.add((c.r << 16) | (c.g << 8) | c.b);
      }
    }
    stdout.writeln(
      '${mode.name.padRight(16)}'
      '${blur3.$1.toStringAsFixed(2).padLeft(8)}'
      '${blur3.$2.toStringAsFixed(2).padLeft(8)}'
      '${blur5.$2.toStringAsFixed(2).padLeft(8)}'
      '${solution.blockHeightSpan.toString().padLeft(7)}'
      '${colours.length.toString().padLeft(9)}',
    );
  }
}

RgbaImage solidHair(int width, int height) {
  final image = RgbaImage(width, height);
  const hair = Rgb(178, 235, 240);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setRgb(x, y, hair);
    }
  }
  return image;
}

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

(double, double) _errors(RgbaImage target, RgbaImage rendered, int radius) {
  var pointwise = 0.0;
  for (var y = 0; y < target.height; y++) {
    for (var x = 0; x < target.width; x++) {
      pointwise += _deltaE(target.pixelAt(x, y), rendered.pixelAt(x, y));
    }
  }
  final count = target.width * target.height;
  final a = _blur(target, radius);
  final b = _blur(rendered, radius);
  var blurred = 0.0;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      blurred += _deltaE(a.pixelAt(x, y), b.pixelAt(x, y));
    }
  }
  return (pointwise / count, blurred / count);
}

double _deltaE(Rgb a, Rgb b) =>
    Lab.fromRgb(a.r, a.g, a.b).distanceTo(Lab.fromRgb(b.r, b.g, b.b));

RgbaImage _blur(RgbaImage image, int radius) {
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
