// Answers "what does a pure white area actually become", with and without the
// neutral guard, and how the two dither thresholds interact with it.
//
// Usage, from the mapart_core package root:
//   dart run tool/white_probe.dart
import 'dart:convert';
import 'dart:io';

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
  final palette = Palette.blocks(
    table,
    '1.20',
    gameVersion: '26.1.2',
    includeSupportBlocks: true,
  ).withBlockColors(_blockColors(), host: table.colors.first);
  final byIndex = {for (var i = 0; i < palette.length; i++) i: palette.entries[i]};

  // Pure white, and the pale blue-grey of the blue-hair background.
  const targets = <String, Rgb>{
    'pure white': Rgb(255, 255, 255),
    'hair bg #eef4fa': Rgb(238, 244, 250),
  };

  stdout.writeln(
    '${'target'.padRight(18)}${'guard'.padRight(8)}${'thr'.padLeft(5)}'
    '${'mean'.padLeft(10)}${'b-r'.padLeft(6)}  blocks used',
  );
  for (final entry in targets.entries) {
    for (final guard in [0.0, 1.0, 3.0]) {
      for (final threshold in [8.0, 0.0]) {
        final source = _solid(32, 32, entry.value);
        final quantized = quantize(
          source: source,
          palette: palette,
          options: QuantizeOptions(
            dither: DitherMode.floydSteinberg,
            metric: ColorMetric.chromaWeighted,
            ditherThreshold: threshold,
            neutralChromaWeight: guard,
          ),
        );
        final solution = solveHeights(
          quantized: quantized,
          options: const HeightSolverOptions(flatnessWeight: 0),
        );
        final rendered = renderMap(
          solution: solution,
          quantized: quantized,
          palette: palette,
        );
        var r = 0, g = 0, b = 0;
        final used = <int>{};
        for (var y = 0; y < rendered.height; y++) {
          for (var x = 0; x < rendered.width; x++) {
            final c = rendered.pixelAt(x, y);
            r += c.r;
            g += c.g;
            b += c.b;
            used.add(
              quantized.paletteIndexAt(solution.tierAt(x, y), x, y),
            );
          }
        }
        final n = rendered.width * rendered.height;
        final names = used.map((i) => byIndex[i]!.blockId).toList()..sort();
        final meanR = r ~/ n;
        final meanG = g ~/ n;
        final meanB = b ~/ n;
        final mean =
            '#${meanR.toRadixString(16).padLeft(2, '0')}'
            '${meanG.toRadixString(16).padLeft(2, '0')}'
            '${meanB.toRadixString(16).padLeft(2, '0')}';
        final list = names.take(4).join(', ') + (names.length > 4 ? ' …' : '');
        stdout.writeln(
          '${entry.key.padRight(18)}'
          '${guard.toStringAsFixed(1).padRight(8)}'
          '${threshold.toStringAsFixed(0).padLeft(5)}'
          '${mean.padLeft(10)}'
          '${(meanB - meanR).toString().padLeft(6)}'
          '  $list',
        );
      }
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
