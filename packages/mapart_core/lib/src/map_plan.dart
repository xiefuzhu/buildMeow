import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'art_kind.dart';
import 'block_names.dart';
import 'height_map.dart';
import 'palette.dart';
import 'quantize.dart';
import 'rgb.dart';
import 'shade_tier.dart';
import 'version_table.dart';

/// One block the finished picture actually places.
///
/// A palette entry carries everything the matcher needed; this carries what the
/// interface and the exporters need, and nothing else. The three tones are
/// resolved once here rather than looked up through the palette at every draw,
/// because the material list, the blueprint and the viewer all want them.
@immutable
class PlanBlock {
  const PlanBlock({
    required this.key,
    required this.blockId,
    required this.blockState,
    required this.nameEn,
    required this.nameZh,
    required this.bright,
    required this.normal,
    required this.dark,
  });

  /// Stable identity of the (base colour, block) pair, i.e.
  /// `PaletteEntry.key`. The hidden-block set is keyed by this, so it survives
  /// a palette reload the way the palette's own indices would not.
  final String key;

  /// Block id without a namespace, e.g. `white_concrete`. This is what the
  /// material list and the file names use.
  final String blockId;

  /// The full block state string the export files carry, e.g.
  /// `minecraft:oak_log[axis=y]`.
  final String blockState;

  /// The English name, e.g. `White Concrete`.
  final String nameEn;

  /// The Simplified Chinese name, or [nameEn] when the game's language file has
  /// none — which happens only for the two entities the extractor surfaced,
  /// an item frame and a glowing item frame.
  final String nameZh;

  /// The map colour this block shows at each of the three staircase shades.
  final Rgb bright;
  final Rgb normal;
  final Rgb dark;

  /// Whether raising the block does not change its colour.
  ///
  /// True when the palette is built from per-block texture averages rather than
  /// the map colour table: a texture average is the block's own colour, so the
  /// three shades are the same. The build is then one layer thick.
  bool get ignoresShade => bright == normal && normal == dark;

  Rgb tone(ShadeTier tier) => switch (tier) {
    ShadeTier.bright => bright,
    ShadeTier.normal => normal,
    ShadeTier.dark => dark,
    ShadeTier.water => throw StateError(
      'ShadeTier.water is not reachable by staircase mapart',
    ),
  };

  @override
  String toString() => 'PlanBlock($key, $blockState, $nameEn / $nameZh)';
}

/// The finished picture, as data rather than as an image.
///
/// This is the seam every later step reads: the material list, the blueprint
/// viewer, the PDF/PNG/CSV sheets and the `.litematic` / `.schem` writers all
/// work from a [MapPlan] rather than from the solver's internals. It is also
/// what makes the round trip checkable — a plan can be written to a structure
/// and read back, and the colours it produces must not change.
///
/// The shade of a pixel is deliberately **not** stored: it is derived from the
/// heights by the same [ShadeTier.fromHeightDelta] rule the renderer uses, so
/// the two cannot drift apart.
@immutable
class MapPlan {
  bool get isFlatMap =>
      artKind == ArtKind.mapItem &&
      blocks.isNotEmpty &&
      blocks.every((block) => block.ignoresShade);
  const MapPlan._({
    required this.width,
    required this.height,
    required this.heights,
    required this.cells,
    required this.blocks,
    required this.counts,
    required this.referenceRowHeight,
    required this.minHeight,
    required this.maxHeight,
    required this.versionId,
    required this.dataVersion,
    required this.artKind,
    required this.fitsWorld,
  });

  /// Map pixels across and down, i.e. `mapsX * 128` and `mapsY * 128`.
  final int width;
  final int height;

  /// Absolute Y per map pixel, `y * width + x`, north row first.
  final Int32List heights;

  /// Which block each map pixel is, as an index into [blocks].
  final Int32List cells;

  /// The blocks the picture places, most-used first.
  ///
  /// Only blocks that are actually used: a palette of 300 that places 90 of
  /// them gives a 90-entry list, which is what the material list and the
  /// schematic palettes should contain.
  final List<PlanBlock> blocks;

  /// How many pixels each entry of [blocks] serves. Parallel to [blocks].
  final List<int> counts;

  /// Absolute Y of the extra row north of the map, which decides the shade of
  /// row 0. It is part of the build even though it is not part of the picture.
  final int referenceRowHeight;

  final int minHeight;
  final int maxHeight;

  final String versionId;
  final int dataVersion;
  final ArtKind artKind;
  final bool fitsWorld;
  bool get requiresReferenceRow => artKind == ArtKind.mapItem;

  int get mapsX => width ~/ 128;
  int get mapsY => height ~/ 128;
  int get mapCount => mapsX * mapsY;
  int get pixelCount => width * height;

  /// How many block layers the build spans, reference row included.
  int get blockHeightSpan {
    final int highest = math.max(maxHeight, referenceRowHeight);
    final int lowest = math.min(minHeight, referenceRowHeight);
    return highest - lowest + 1;
  }

  /// How many blocks the picture places, reference row excluded.
  int get totalBlocks {
    var total = 0;
    for (final count in counts) {
      total += count;
    }
    return total;
  }

  int heightAt(int x, int y) => heights[y * width + x];

  /// The height of the block this pixel is compared against: the one to its
  /// north, or the reference row for the northern edge.
  int northHeightAt(int x, int y) =>
      y == 0 ? referenceRowHeight : heightAt(x, y - 1);

  /// How much higher this pixel is than the one north of it: `-1`, `0` or `1`.
  int relativeHeightAt(int x, int y) => heightAt(x, y) - northHeightAt(x, y);

  /// The shade this pixel shows, derived from the solved heights.
  ShadeTier tierAt(int x, int y) =>
      ShadeTier.fromHeightDelta(relativeHeightAt(x, y));

  int blockIndexAt(int x, int y) => cells[y * width + x];

  PlanBlock blockAt(int x, int y) => blocks[blockIndexAt(x, y)];

  /// The map colour this pixel shows, i.e. what the game's map will paint.
  Rgb colorAt(int x, int y) => blockAt(x, y).tone(tierAt(x, y));

  /// The index of the block with [key], or `-1` when the picture does not use
  /// it.
  int indexOfKey(String key) {
    for (var i = 0; i < blocks.length; i++) {
      if (blocks[i].key == key) return i;
    }
    return -1;
  }

  /// The pixels of one map tile, as `(x, y)` bounds, for the blueprint sheets.
  ({int x0, int y0, int x1, int y1}) tileBounds(int tileX, int tileY) => (
    x0: tileX * 128,
    y0: tileY * 128,
    x1: math.min((tileX + 1) * 128, width),
    y1: math.min((tileY + 1) * 128, height),
  );

  @override
  String toString() =>
      'MapPlan($width x $height, ${blocks.length} blocks, '
      'Y $minHeight..$maxHeight, reference row $referenceRowHeight)';
}

/// Turns a solved, matched picture into the data every later step reads.
///
/// [names] is only used to label blocks; a missing Chinese name falls back to
/// the English one, so an empty [BlockNames] is a legitimate input.
MapPlan buildMapPlan({
  required HeightSolution solution,
  required QuantizedImage quantized,
  required Palette palette,
  required MinecraftVersion version,
  BlockNames names = BlockNames.empty,
  ArtKind? artKind,
}) {
  final width = solution.width;
  final height = solution.height;
  if (width != quantized.width || height != quantized.height) {
    throw ArgumentError(
      'the solution is ${width}x$height but the matched image is '
      '${quantized.width}x${quantized.height}',
    );
  }

  final pixelCount = width * height;
  final usage = Int32List(palette.length);
  final chosen = Int32List(pixelCount);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final p = y * width + x;
      final index = quantized.paletteIndexAt(solution.tierAt(x, y), x, y);
      chosen[p] = index;
      usage[index]++;
    }
  }

  // Most-used first, and ties broken by palette order so the list is stable
  // between runs and between identical solves.
  final order =
      <int>[
        for (var i = 0; i < palette.length; i++)
          if (usage[i] > 0) i,
      ]..sort((a, b) {
        final byCount = usage[b].compareTo(usage[a]);
        return byCount != 0 ? byCount : a.compareTo(b);
      });

  final blocks = <PlanBlock>[
    for (final index in order) _planBlock(palette.entries[index], names),
  ];
  final counts = <int>[for (final index in order) usage[index]];

  final remap = Int32List(palette.length)..fillRange(0, palette.length, -1);
  for (var i = 0; i < order.length; i++) {
    remap[order[i]] = i;
  }
  final cells = Int32List(pixelCount);
  for (var p = 0; p < pixelCount; p++) {
    cells[p] = remap[chosen[p]];
  }

  return MapPlan._(
    width: width,
    height: height,
    heights: solution.heights,
    cells: cells,
    blocks: List.unmodifiable(blocks),
    counts: List.unmodifiable(counts),
    referenceRowHeight: solution.referenceRowHeight,
    minHeight: solution.minHeight,
    maxHeight: solution.maxHeight,
    versionId: version.id,
    dataVersion: version.dataVersion,
    artKind:
        artKind ??
        (palette.ignoresShade ? ArtKind.blockPixels : ArtKind.mapItem),
    fitsWorld:
        math.min(solution.minHeight, solution.referenceRowHeight) >=
            version.minY &&
        math.max(solution.maxHeight, solution.referenceRowHeight) <=
            version.maxY,
  );
}

PlanBlock _planBlock(PaletteEntry entry, BlockNames names) => PlanBlock(
  key: entry.key,
  blockId: entry.blockId,
  blockState: entry.state.toBlockStateString(),
  nameEn: entry.blockName,
  nameZh: names.zhOr(entry.blockId, entry.blockName),
  bright: entry.tone(ShadeTier.bright),
  normal: entry.tone(ShadeTier.normal),
  dark: entry.tone(ShadeTier.dark),
);
