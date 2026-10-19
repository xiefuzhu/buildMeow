// Visual workbench for judging colour fidelity on a real picture.
//
// Runs the pipeline under several configurations, writes a PNG for each, and
// reports how far the result is from the resized source — both per pixel and
// after blurring, which is the fair way to judge dithering: error diffusion
// deliberately raises per-pixel error to lower the error the eye actually sees.
//
// Usage, from the mapart_core package root:
//   dart run tool/palette_lab.dart [source image] [output directory] [mapsX] [mapsY]
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:mapart_core/mapart_core.dart';

const String _outDir = 'build/palette_lab';

late final ColorTable table;
late final Palette palette;
late final int worldBudget;
void main(List<String> args) {
  final sourcePath = args.isNotEmpty
      ? args[0]
      : r'C:\Users\xiefuzhu\Pictures\B077CD3898AD5AA5511D581BD5CDFD0C.jpg';
  final outDir = Directory(args.length > 1 ? args[1] : _outDir)
    ..createSync(recursive: true);
  final mapsX = args.length > 2 ? int.parse(args[2]) : 1;
  final mapsY = args.length > 3 ? int.parse(args[3]) : 1;

  table = ColorTable.fromJson(
    jsonDecode(File('assets/colors/mapartcraft.colors.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  palette = Palette.select(table, '1.20');
  final versions = VersionTable.fromJson(
    jsonDecode(File('assets/colors/versions.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final version = versions.latest;
  final plan = suggestHeightPlan(version);
  worldBudget = plan.driftBudget;
  stdout.writeln(
    'target ${version.id}: Y ${version.minY}..${version.maxY}, '
    'suggested drift budget $worldBudget (max span '
    '${2 * worldBudget + 1} layers), base height ${plan.baseHeight}',
  );

  final decoded = img.decodeImage(File(sourcePath).readAsBytesSync());
  if (decoded == null) {
    stderr.writeln('could not decode $sourcePath');
    exitCode = 1;
    return;
  }
  final source = _toRgbaImage(decoded);
  stdout.writeln('source: $sourcePath (${decoded.width}x${decoded.height})');

  final grid = fitToGrid(
    source,
    mapsX * 128,
    mapsY * 128,
    mode: CropMode.cover,
    background: const Rgb(255, 255, 255),
  );
  _writePng(outDir, '00_target.png', grid, scale: 4);

  final variants = <_Variant>[
    _Variant('10_plain', DitherMode.none),
    _Variant(
      '11_plain_exact',
      DitherMode.none,
      heights: const HeightSolverOptions(flatnessWeight: 0),
    ),
    _Variant('20_dither_free', DitherMode.floydSteinberg),
    _Variant('21_dither_world', DitherMode.floydSteinberg, useWorldBudget: true),
    _Variant('22_dither_b96', DitherMode.floydSteinberg, driftBudget: 96),
    _Variant('23_dither_b64', DitherMode.floydSteinberg, driftBudget: 64),
    _Variant('24_dither_b32', DitherMode.floydSteinberg, driftBudget: 32),
    _Variant('25_dither_thr20', DitherMode.floydSteinberg, ditherThreshold: 20),
    _Variant('26_dither_thr0', DitherMode.floydSteinberg, ditherThreshold: 0),
    _Variant(
      '30_dither_ciede2000',
      DitherMode.floydSteinberg,
      metric: ColorMetric.ciede2000,
    ),
    _Variant(
      '31_dither_strength050',
      DitherMode.floydSteinberg,
      ditherStrength: 0.5,
    ),
  ];

  stdout.writeln('');
  stdout.writeln(
    '${'variant'.padRight(20)}${'px mean'.padLeft(9)}${'px p95'.padLeft(8)}'
    '${'blur mean'.padLeft(11)}${'exact %'.padLeft(9)}${'>40 %'.padLeft(8)}'
    '${'span'.padLeft(7)}${'quant ms'.padLeft(10)}',
  );
  stdout.writeln('-' * 82);

  for (final variant in variants) {
    final report = _run(grid, variant, outDir);
    stdout.writeln(
      '${variant.name.padRight(20)}'
      '${report.pixelMean.toStringAsFixed(2).padLeft(9)}'
      '${report.pixelP95.toStringAsFixed(1).padLeft(8)}'
      '${report.blurredMean.toStringAsFixed(2).padLeft(11)}'
      '${report.exactPercent.toStringAsFixed(1).padLeft(9)}'
      '${report.outlierPercent.toStringAsFixed(2).padLeft(8)}'
      '${report.span.toString().padLeft(7)}'
      '${report.quantizeMs.toString().padLeft(10)}',
    );
  }

  _writePaletteChart(outDir);
  stdout.writeln('');
  stdout.writeln('wrote PNGs to ${outDir.path}');
}

class _Variant {
  _Variant(
    this.name,
    this.dither, {
    this.ditherStrength = 1.0,
    this.ditherThreshold = 8.0,
    this.driftBudget,
    this.useWorldBudget = false,
    this.heights = const HeightSolverOptions(),
    this.metric = ColorMetric.cie76,
  });

  final String name;
  final DitherMode dither;
  final double ditherStrength;
  final double ditherThreshold;
  final int? driftBudget;
  final bool useWorldBudget;
  final HeightSolverOptions heights;
  final ColorMetric metric;
}

class _Report {
  _Report({
    required this.pixelMean,
    required this.pixelP95,
    required this.blurredMean,
    required this.exactPercent,
    required this.outlierPercent,
    required this.span,
    required this.quantizeMs,
  });

  final double pixelMean;
  final double pixelP95;
  final double blurredMean;
  final double exactPercent;

  /// Share of pixels landed on a colour more than 40 deltaE from the source.
  /// These are the blowouts: individual blocks that look painted in by mistake.
  final double outlierPercent;

  final int span;
  final int quantizeMs;
}

_Report _run(RgbaImage grid, _Variant variant, Directory outDir) {
  final watch = Stopwatch()..start();
  final quantized = quantize(
    source: grid,
    palette: palette,
    options: QuantizeOptions(
      dither: variant.dither,
      ditherStrength: variant.ditherStrength,
      ditherThreshold: variant.ditherThreshold,
      driftBudget: variant.useWorldBudget ? worldBudget : variant.driftBudget,
      metric: variant.metric,
    ),
  );
  final quantizeMs = watch.elapsedMilliseconds;
  final solution = solveHeights(
    quantized: quantized,
    options: variant.heights,
  );
  final rendered = renderMap(
    solution: solution,
    quantized: quantized,
    palette: palette,
  );
  _writePng(outDir, '${variant.name}.png', rendered, scale: 4);

  final errors = <double>[];
  var exact = 0;
  var outliers = 0;
  for (var y = 0; y < grid.height; y++) {
    for (var x = 0; x < grid.width; x++) {
      final target = grid.pixelAt(x, y);
      final got = rendered.pixelAt(x, y);
      if (target == got) {
        exact++;
        continue;
      }
      final delta = _deltaE(target, got);
      // A "blowout": error diffusion that has drifted so far it lands on a
      // colour with nothing to do with the source pixel. These are the
      // individual blocks that look like they were painted in by mistake.
      if (delta > 40) outliers++;
      errors.add(delta);
    }
  }
  errors.sort();

  final blurredTarget = _boxBlur(grid, 2);
  final blurredRendered = _boxBlur(rendered, 2);
  var blurredTotal = 0.0;
  for (var y = 0; y < grid.height; y++) {
    for (var x = 0; x < grid.width; x++) {
      blurredTotal += _deltaE(
        blurredTarget.pixelAt(x, y),
        blurredRendered.pixelAt(x, y),
      );
    }
  }

  return _Report(
    pixelMean: errors.isEmpty
        ? 0
        : errors.reduce((a, b) => a + b) / errors.length,
    pixelP95: errors.isEmpty
        ? 0
        : errors[(errors.length * 0.95).floor().clamp(0, errors.length - 1)],
    blurredMean: blurredTotal / (grid.width * grid.height),
    exactPercent: 100 * exact / (grid.width * grid.height),
    outlierPercent: 100 * outliers / (grid.width * grid.height),
    span: solution.maxHeight - solution.minHeight,
    quantizeMs: quantizeMs,
  );
}

double _deltaE(Rgb a, Rgb b) => Lab.fromRgb(a.r, a.g, a.b).distanceTo(
  Lab.fromRgb(b.r, b.g, b.b),
);

RgbaImage _boxBlur(RgbaImage image, int radius) {
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

/// A swatch per palette entry per shade, so a gap or a duplicate is visible at a
/// glance. Rows are base colours, columns are the three staircase shades.
void _writePaletteChart(Directory outDir) {
  const swatch = 24;
  const labelWidth = 150;
  final rows = palette.length;
  final image = img.Image(
    width: labelWidth + swatch * 3,
    height: rows * swatch,
    numChannels: 3,
  );
  img.fill(image, color: img.ColorRgb8(255, 255, 255));

  for (var row = 0; row < rows; row++) {
    final entry = palette.entries[row];
    for (var col = 0; col < 3; col++) {
      final tone = entry.tone(ShadeTier.staircase[col]);
      img.fillRect(
        image,
        x1: labelWidth + col * swatch,
        y1: row * swatch,
        x2: labelWidth + (col + 1) * swatch - 1,
        y2: (row + 1) * swatch - 1,
        color: img.ColorRgb8(tone.r, tone.g, tone.b),
      );
    }
  }
  File('${outDir.path}/90_palette_chart.png').writeAsBytesSync(
    img.encodePng(image),
  );
}

void _writePng(
  Directory outDir,
  String name,
  RgbaImage image, {
  required int scale,
}) {
  final out = img.Image(
    width: image.width * scale,
    height: image.height * scale,
    numChannels: 3,
  );
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final p = image.pixelAt(x, y);
      for (var dy = 0; dy < scale; dy++) {
        for (var dx = 0; dx < scale; dx++) {
          out.setPixelRgb(x * scale + dx, y * scale + dy, p.r, p.g, p.b);
        }
      }
    }
  }
  File('${outDir.path}/$name').writeAsBytesSync(img.encodePng(out));
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
