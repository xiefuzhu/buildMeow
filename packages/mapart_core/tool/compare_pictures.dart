// Compares the two picture uses on a fixed set of images.
//
// Scores are not the matcher's own distance. CIE76 blurred error is reported
// only so it can be seen next to a CIEDE2000 blurred error and an SSIM of the
// same blurred pictures. SSIM does not use Lab at all.
//
// Put images in test/pictures/ (jpg or png). The three supplied so far:
//   01_anime_portrait  grey-haired figure, skin and hair gradients
//   02_anime_flat      large flat colours
//   03_portrait        rendered face, high detail
//
// Usage, from the mapart_core package root:
//   dart run tool/compare_pictures.dart [mapsX] [mapsY]
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:mapart_core/mapart_core.dart';

void main(List<String> args) {
  final mapsX = args.isNotEmpty ? int.parse(args[0]) : 1;
  final mapsY = args.length > 1 ? int.parse(args[1]) : 1;
  final pictures = Directory('test/pictures');
  if (!pictures.existsSync()) pictures.createSync(recursive: true);
  final files = pictures
      .listSync()
      .whereType<File>()
      .where((f) {
        final name = f.uri.pathSegments.last.toLowerCase();
        return name.endsWith('.png') ||
            name.endsWith('.jpg') ||
            name.endsWith('.jpeg');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    stderr.writeln(
      'no pictures in ${pictures.absolute.path}\n'
      'save the test set there, then re-run. Expected names:\n'
      '  01_anime_portrait.jpg\n'
      '  02_anime_flat.jpg\n'
      '  03_portrait.jpg',
    );
    exitCode = 1;
    return;
  }

  final table = ColorTable.fromJson(
    jsonDecode(File('assets/colors/mapartcraft.colors.json').readAsStringSync())
        as Map<String, dynamic>,
  ).includingGameBlocks(
    jsonDecode(File('assets/colors/block_map_colors.json').readAsStringSync())
        as Map<String, dynamic>,
    '26.1.2',
  );
  final versions = VersionTable.fromJson(
    jsonDecode(File('assets/colors/versions.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final version = versions.require('26.1.2');
  final blocks = Palette.blocks(
    table,
    version.blockSetAlias,
    gameVersion: version.id,
    includeSupportBlocks: true,
  );
  final textured = blocks.withBlockColors(
    _blockColors(),
    host: table.colors.first,
  );
  final outDir = Directory('build/compare')..createSync(recursive: true);

  stdout.writeln(
    'blur is a 5x5 box. cie76 and de00 are mean distance after that blur. '
    'ssim is global SSIM of the same blurred pictures (1 is identical).',
  );
  stdout.writeln(
    'raw is CIE76 with no blur. top20 is the share of pixels the most-used '
    '20 blocks serve.',
  );
  stdout.writeln(
    '${'picture'.padRight(28)}${'use'.padRight(8)}'
    '${'raw'.padLeft(7)}${'cie76'.padLeft(8)}${'de00'.padLeft(8)}'
    '${'ssim'.padLeft(8)}${'blocks'.padLeft(8)}${'top20'.padLeft(8)}'
    '${'span'.padLeft(6)}',
  );

  for (final file in files) {
    final decoded = img.decodeImage(file.readAsBytesSync());
    if (decoded == null) {
      stderr.writeln('could not decode ${file.path}');
      continue;
    }
    final source = _toRgba(decoded);
    final grid = fitToGrid(
      source,
      mapsX * 128,
      mapsY * 128,
      mode: CropMode.cover,
      background: const Rgb(255, 255, 255),
    );
    final name = file.uri.pathSegments.last;
    final stem = name.replaceAll(RegExp(r'\.(png|jpe?g)$', caseSensitive: false), '');
    final panels = <RgbaImage>[grid];
    for (final (label, palette) in [('block', textured), ('map', blocks)]) {
      final report = _run(grid, palette, version);
      panels.add(report.rendered);
      stdout.writeln(
        '${name.padRight(28)}${label.padRight(8)}'
        '${report.raw.toStringAsFixed(2).padLeft(7)}'
        '${report.cie76.toStringAsFixed(2).padLeft(8)}'
        '${report.de00.toStringAsFixed(2).padLeft(8)}'
        '${report.ssim.toStringAsFixed(3).padLeft(8)}'
        '${report.blocks.toString().padLeft(8)}'
        '${(report.top20 * 100).toStringAsFixed(0).padLeft(7)}%'
        '${report.span.toString().padLeft(6)}',
      );
    }
    final strip = _sideBySide(panels, scale: 3);
    final out = File('${outDir.path}/$stem.png');
    out.writeAsBytesSync(img.encodePng(_toImage(strip)));
    stdout.writeln('  wrote ${out.path}  (target | block pixels | map item)');

    // What the two new controls cost, on the block-pixels path.
    stdout.writeln('  block pixels, dither strength / cap:');
    stdout.writeln(
      '    ${'strength'.padRight(10)}${'cap'.padRight(7)}'
      '${'raw'.padLeft(7)}${'cie76'.padLeft(8)}${'de00'.padLeft(8)}'
      '${'blocks'.padLeft(8)}${'top20'.padLeft(8)}',
    );
    for (final (label, strength, cap) in <(String, double, int?)>[
      ('100%', 1.0, null),
      ('75%', 0.75, null),
      ('50%', 0.5, null),
      ('100%', 1.0, 60),
      ('100%', 1.0, 40),
      ('100%', 1.0, 20),
    ]) {
      final r = _run(grid, textured, version, ditherStrength: strength, maxBlocks: cap);
      stdout.writeln(
        '    ${label.padRight(10)}'
        '${(cap == null ? 'none' : '$cap').padRight(7)}'
        '${r.raw.toStringAsFixed(2).padLeft(7)}'
        '${r.cie76.toStringAsFixed(2).padLeft(8)}'
        '${r.de00.toStringAsFixed(2).padLeft(8)}'
        '${r.blocks.toString().padLeft(8)}'
        '${(r.top20 * 100).toStringAsFixed(0).padLeft(7)}%',
      );
    }
  }
}

({RgbaImage rendered, double raw, double cie76, double de00, double ssim,
  int blocks, double top20, int span})
_run(
  RgbaImage grid,
  Palette palette,
  MinecraftVersion version, {
  double ditherStrength = 1.0,
  int? maxBlocks,
}) {
  final plan = suggestHeightPlan(version);
  final quantized = quantize(
    source: grid,
    palette: palette,
    options: QuantizeOptions(
      dither: DitherMode.floydSteinberg,
      metric: ColorMetric.chromaWeighted,
      ditherStrength: ditherStrength,
      maxBlocks: maxBlocks,
      driftBudget: palette.ignoresShade ? null : plan.driftBudget,
    ),
  );
  final solution = solveHeights(
    quantized: quantized,
    version: version,
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
  final blurredGrid = _blur(grid, 2);
  final blurredOut = _blur(rendered, 2);
  final usage = <int, int>{};
  for (var y = 0; y < solution.height; y++) {
    for (var x = 0; x < solution.width; x++) {
      final index = quantized.paletteIndexAt(solution.tierAt(x, y), x, y);
      usage[index] = (usage[index] ?? 0) + 1;
    }
  }
  final ranked = usage.values.toList()..sort((a, b) => b.compareTo(a));
  final total = solution.width * solution.height;
  var top20 = 0;
  for (var i = 0; i < 20 && i < ranked.length; i++) {
    top20 += ranked[i];
  }
  return (
    rendered: rendered,
    raw: _mean(grid, rendered, _cie76),
    cie76: _mean(blurredGrid, blurredOut, _cie76),
    de00: _mean(blurredGrid, blurredOut, _de00),
    ssim: _ssim(blurredGrid, blurredOut),
    blocks: usage.length,
    top20: top20 / total,
    span: solution.blockHeightSpan,
  );
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
  const emptyFace = {
    'notAFullCube',
    'multipart',
    'noGeometry',
    'translucent',
    'animated',
    'undecodable',
    'noTexture',
  };
  final fallback = <String, int>{};
  final preferred = <String, int>{};
  for (final raw in json['blocks'] as List) {
    final block = raw as Map<String, dynamic>;
    final srgb = block['srgb'];
    if (srgb is! List || srgb.length != 3) continue;
    final id = block['block'] as String;
    if (id.contains('glass') || id == 'beacon') continue;
    if (block['excluded'] == 'translucent') continue;
    final opaque = block['opaquePixels'];
    if (opaque is num && opaque < 200) continue;
    if (emptyFace.contains(block['excluded'])) continue;
    if (!kept.contains(id)) continue;
    final packed =
        ((srgb[0] as num).toInt() << 16) |
        ((srgb[1] as num).toInt() << 8) |
        (srgb[2] as num).toInt();
    if (block['excluded'] == null) {
      preferred[id] = packed;
    } else {
      fallback.putIfAbsent(id, () => packed);
    }
  }
  return {...fallback, ...preferred};
}

double _mean(
  RgbaImage a,
  RgbaImage b,
  double Function(Rgb, Rgb) distance,
) {
  var sum = 0.0;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      sum += distance(a.pixelAt(x, y), b.pixelAt(x, y));
    }
  }
  return sum / (a.width * a.height);
}

double _cie76(Rgb a, Rgb b) =>
    Lab.fromRgb(a.r, a.g, a.b).distanceTo(Lab.fromRgb(b.r, b.g, b.b));

double _de00(Rgb a, Rgb b) =>
    Lab.fromRgb(a.r, a.g, a.b).ciede2000To(Lab.fromRgb(b.r, b.g, b.b));

/// Global SSIM on Rec.709 luma. Independent of whichever Lab metric matched.
double _ssim(RgbaImage a, RgbaImage b) {
  final n = a.width * a.height;
  var meanA = 0.0, meanB = 0.0;
  final la = List<double>.filled(n, 0);
  final lb = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final y = i ~/ a.width;
    final x = i % a.width;
    la[i] = _luma(a.pixelAt(x, y));
    lb[i] = _luma(b.pixelAt(x, y));
    meanA += la[i];
    meanB += lb[i];
  }
  meanA /= n;
  meanB /= n;
  var varA = 0.0, varB = 0.0, cov = 0.0;
  for (var i = 0; i < n; i++) {
    final da = la[i] - meanA;
    final db = lb[i] - meanB;
    varA += da * da;
    varB += db * db;
    cov += da * db;
  }
  varA /= n;
  varB /= n;
  cov /= n;
  const l = 255.0;
  const c1 = (0.01 * l) * (0.01 * l);
  const c2 = (0.03 * l) * (0.03 * l);
  return ((2 * meanA * meanB + c1) * (2 * cov + c2)) /
      ((meanA * meanA + meanB * meanB + c1) * (varA + varB + c2));
}

double _luma(Rgb c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;

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

RgbaImage _sideBySide(List<RgbaImage> panels, {required int scale}) {
  const gap = 4;
  final width = panels.fold<int>(
    gap * (panels.length - 1),
    (sum, panel) => sum + panel.width * scale,
  );
  final height = panels.first.height * scale;
  final out = RgbaImage(width, height);
  var x0 = 0;
  for (final panel in panels) {
    for (var y = 0; y < panel.height; y++) {
      for (var x = 0; x < panel.width; x++) {
        final color = panel.pixelAt(x, y);
        for (var dy = 0; dy < scale; dy++) {
          for (var dx = 0; dx < scale; dx++) {
            out.setRgb(x0 + x * scale + dx, y * scale + dy, color);
          }
        }
      }
    }
    x0 += panel.width * scale + gap;
  }
  return out;
}

img.Image _toImage(RgbaImage image) {
  final out = img.Image(width: image.width, height: image.height);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final p = image.pixelAt(x, y);
      out.setPixelRgba(x, y, p.r, p.g, p.b, 255);
    }
  }
  return out;
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
