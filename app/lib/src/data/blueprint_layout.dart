import 'package:mapart_core/mapart_core.dart';
import 'package:meta/meta.dart';

/// One entry of a tile's legend: a block and how many of it that tile uses.
@immutable
class LegendEntry {
  const LegendEntry({required this.block, required this.count});

  final PlanBlock block;
  final int count;
}

/// One map tile of the blueprint: where it is in the picture, and what it is
/// built from.
@immutable
class BlueprintTile {
  const BlueprintTile({
    required this.index,
    required this.column,
    required this.row,
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.legend,
    required this.blocks,
  });

  /// Zero-based, in the order the maps are numbered: west to east, then north
  /// to south.
  final int index;

  /// One-based, for what is printed on the sheet.
  final int column;
  final int row;

  final int x0;
  final int y0;
  final int x1;
  final int y1;

  /// The blocks this tile uses, most-used first.
  final List<LegendEntry> legend;

  /// How many blocks the tile places, reference row excluded.
  final int blocks;

  int get width => x1 - x0;
  int get height => y1 - y0;

  /// Whether the extra row north of the picture is above this tile, i.e.
  /// whether this is a tile in the northernmost row.
  bool get hasReferenceRow => row == 1;

  /// The block a cell of this tile is, for the legend's swatch.
  PlanBlock blockAt(MapPlan plan, int x, int y) => plan.blockAt(x, y);
}

/// Splits the picture into its map tiles, each with its own legend.
///
/// The legend is per tile rather than per picture because a sheet is printed one
/// map at a time: a builder working on map three wants to know what map three
/// needs, not what the whole wall needs.
List<BlueprintTile> blueprintTiles(MapPlan plan) {
  final tiles = <BlueprintTile>[];
  for (var row = 0; row < plan.mapsY; row++) {
    for (var column = 0; column < plan.mapsX; column++) {
      final bounds = plan.tileBounds(column, row);
      final counts = <int, int>{};
      for (var y = bounds.y0; y < bounds.y1; y++) {
        for (var x = bounds.x0; x < bounds.x1; x++) {
          final index = plan.blockIndexAt(x, y);
          counts[index] = (counts[index] ?? 0) + 1;
        }
      }
      final order = counts.keys.toList()
        ..sort((a, b) {
          final byCount = counts[b]!.compareTo(counts[a]!);
          return byCount != 0 ? byCount : a.compareTo(b);
        });
      tiles.add(
        BlueprintTile(
          index: tiles.length,
          column: column + 1,
          row: row + 1,
          x0: bounds.x0,
          y0: bounds.y0,
          x1: bounds.x1,
          y1: bounds.y1,
          legend: [
            for (final index in order)
              LegendEntry(block: plan.blocks[index], count: counts[index]!),
          ],
          blocks: bounds.x1 - bounds.x0 == 0
              ? 0
              : (bounds.y1 - bounds.y0) * (bounds.x1 - bounds.x0),
        ),
      );
    }
  }
  return tiles;
}

/// The line under the title on every sheet.
String blueprintSubtitle(MapPlan plan, {String? sourceName}) {
  final parts = <String>[
    '${plan.width} x ${plan.height} 格 · ${plan.mapsX} x ${plan.mapsY} 张地图'
        '${plan.isFlatMap ? ' · 单层地图画' : ''}',
    'Minecraft ${plan.versionId}',
    '高度 Y ${plan.minHeight}..${plan.maxHeight} (${plan.blockHeightSpan} 层)',
  ];
  if (sourceName != null && sourceName.isNotEmpty) {
    parts.insert(0, sourceName);
  }
  return parts.join(' · ');
}

/// The note every sheet carries about the row that is built but not shown.
String blueprintReferenceNote(MapPlan plan) => plan.requiresReferenceRow
    ? plan.isFlatMap
          ? '单层地图画的参照行与画面同高(Y ${plan.referenceRowHeight})，用于保持最北行的地图颜色。'
          : '地图最北边要多建一行参照方块(Y ${plan.referenceRowHeight}),'
                '它在图外,不参与画面。它的高度决定了第一行的明暗,不能省。'
    : '方块像素画为单层构建，不需要参照行；贴图预览按标准光照近似。';

/// The note about lining the build up with the game's map grid.
///
/// Maps are 128 blocks square and aligned to a fixed grid whose boundaries sit
/// at `64 + 128k`, so a build that is one block out shows a picture that is one
/// block out.
String blueprintAlignmentNote([MapPlan? plan]) =>
    plan != null && !plan.requiresReferenceRow
    ? '方块像素画可自由摆放；图纸坐标为作品内坐标。'
    : '游戏里的地图格子是固定的:西北角要落在 X 和 Z 都满足 64 + 128 的整数倍的位置上,'
          '否则地图会看到偏移一格的画面。';

/// How much of the picture a tile covers, as `1/4` style text.
String tileLabel(BlueprintTile tile) =>
    '第 ${tile.index + 1} 张 · 第 ${tile.row} 行 第 ${tile.column} 列';
