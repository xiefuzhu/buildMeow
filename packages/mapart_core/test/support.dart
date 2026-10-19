import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:mapart_core/mapart_core.dart';

/// `dart test` runs with the package root as the working directory, so the
/// vendored assets can be read straight off disk.
File _asset(String name) {
  final file = File('assets/colors/$name');
  if (!file.existsSync()) {
    throw StateError(
      'missing asset ${file.absolute.path} — run `dart test` from the '
      'mapart_core package root',
    );
  }
  return file;
}

Map<String, dynamic> _decode(String name) =>
    jsonDecode(_asset(name).readAsStringSync()) as Map<String, dynamic>;

/// The vendored MapartCraft colour table.
ColorTable loadColorTable() => ColorTable.fromJson(_decode('mapartcraft.colors.json'));

/// The only release this build targets.
VersionTable loadVersionTable() => VersionTable.fromJson(_decode('versions.json'));

/// The 26.1.2 block → map-colour catalogue.
Map<String, dynamic> loadBlockCatalog() => _decode('block_map_colors.json');

/// Each block's own colour, filtered exactly the way the app filters it.
Map<String, int> loadBlockColours() => blockColoursFromTexturePalette(
  _decode('texture_palette_26_1_2.json'),
  keep: loadKeptBlocks(),
);

/// The block ids the texture folder was cleaned down to, or empty when that
/// file has not been written.
Set<String> loadKeptBlocks() {
  final file = File('assets/colors/kept_blocks.json');
  if (!file.existsSync()) return const <String>{};
  return (jsonDecode(file.readAsStringSync()) as List).cast<String>().toSet();
}

/// Minecraft's own Chinese names for blocks.
BlockNames loadBlockNames() => BlockNames.fromJson(
  jsonDecode(File('assets/lang/zh_cn_blocks.json').readAsStringSync())
      as Map<String, dynamic>,
);

/// The palette the app builds: every candidate block, with each block keeping
/// its own texture colour.
Palette loadAppPalette({bool includeSupportBlocks = true}) => Palette.blocks(
  loadColorTable(),
  '1.20',
  gameVersion: '26.1.2',
  includeSupportBlocks: includeSupportBlocks,
).withBlockColors(loadBlockColours(), host: loadColorTable().colors.first);

/// The whole pipeline, from a source image to the colours Minecraft would show.
///
/// This is the acceptance criterion that matters most: the height solver and
/// the renderer have to be exact inverses. The solver picks a shade and walks
/// the height to produce it; the renderer reads the walk back and derives the
/// shade. A sign flip or an off-by-one on the reference row makes them disagree
/// and every preview would be wrong.
class Pipeline {
  Pipeline({
    required this.palette,
    required this.quantized,
    required this.solution,
    required this.rendered,
    required this.requested,
  });

  final Palette palette;
  final QuantizedImage quantized;
  final HeightSolution solution;
  final RgbaImage rendered;

  /// What quantization asked for at every pixel, ignoring heights.
  final RgbaImage requested;

  static Pipeline run(
    RgbaImage source, {
    required Palette palette,
    required int mapsX,
    required int mapsY,
    CropMode cropMode = CropMode.cover,
    DitherMode dither = DitherMode.none,
    // Exactness is a property of the unconstrained solve, so the round-trip
    // tests opt out of the flatness default explicitly.
    HeightSolverOptions heights = const HeightSolverOptions(
      flatnessWeight: 0,
    ),
  }) {
    final grid = fitToGrid(
      source,
      mapsX * 128,
      mapsY * 128,
      mode: cropMode,
      background: const Rgb(255, 255, 255),
    );
    final quantized = quantize(
      source: grid,
      palette: palette,
      options: QuantizeOptions(dither: dither),
    );
    final solution = solveHeights(quantized: quantized, options: heights);
    final rendered = renderMap(
      solution: solution,
      quantized: quantized,
      palette: palette,
    );

    final requested = RgbaImage(grid.width, grid.height);
    for (var y = 0; y < grid.height; y++) {
      for (var x = 0; x < grid.width; x++) {
        requested.setRgb(
          x,
          y,
          bestColorAt(quantized: quantized, palette: palette, x: x, y: y),
        );
      }
    }

    return Pipeline(
      palette: palette,
      quantized: quantized,
      solution: solution,
      rendered: rendered,
      requested: requested,
    );
  }

  /// The same solve, as the data the interface, the blueprint sheets and the
  /// exporters read.
  MapPlan plan({BlockNames names = BlockNames.empty}) => buildMapPlan(
    solution: solution,
    quantized: quantized,
    palette: palette,
    version: loadVersionTable().require(VersionTable.defaultVersionId),
    names: names,
  );
}

RgbaImage gradient(int width, int height) {
  final image = RgbaImage(width, height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final r = (255 * x / math.max(1, width - 1)).round();
      final g = (255 * y / math.max(1, height - 1)).round();
      image.setPixel(x, y, r, g, 128);
    }
  }
  return image;
}

RgbaImage noiseImage(int width, int height, {int seed = 4242}) {
  final random = math.Random(seed);
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

/// A picture with hard horizontal bands, which is what makes a staircase: each
/// band wants a different shade, so the heights have to step.
RgbaImage bands(int width, int height) {
  final image = RgbaImage(width, height);
  for (var y = 0; y < height; y++) {
    final value = (255 * (y % 2)).clamp(0, 255);
    for (var x = 0; x < width; x++) {
      image.setPixel(x, y, value, value, value);
    }
  }
  return image;
}
