import 'package:build_meow/src/data/blueprint_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapart_core/mapart_core.dart';

import 'plan_support.dart';

/// How the picture is cut into the sheets that get printed.
///
/// The split has to agree with the game's own map grid — 128 blocks square,
/// numbered west to east and then north to south — because a sheet is what
/// someone builds one map from, and a sheet that covers the wrong 128 columns
/// sends them to the wrong place.
void main() {
  late MapPlan plan;

  setUpAll(() {
    // Two maps across and two down, so both axes and the reference row rule are
    // exercised.
    plan = buildTestResult(mapsX: 2, mapsY: 2).plan;
  });

  test(
    'a 2x2 picture splits into four tiles, west to east then north to south',
    () {
      final tiles = blueprintTiles(plan);

      expect(tiles, hasLength(4));
      expect(tiles.map((tile) => tile.index), [0, 1, 2, 3]);
      // Row-major: the first two tiles are the northern row.
      expect(tiles.map((tile) => tile.row), [1, 1, 2, 2]);
      expect(tiles.map((tile) => tile.column), [1, 2, 1, 2]);
    },
  );

  test('each tile covers its own 128x128 corner of the picture', () {
    final tiles = blueprintTiles(plan);

    expect(
      (tiles[0].x0, tiles[0].y0, tiles[0].x1, tiles[0].y1),
      (0, 0, 128, 128),
    );
    expect((tiles[1].x0, tiles[1].y0), (128, 0));
    expect((tiles[2].x0, tiles[2].y0), (0, 128));
    expect((tiles[3].x1, tiles[3].y1), (256, 256));

    for (final tile in tiles) {
      expect(tile.width, 128);
      expect(tile.height, 128);
    }
  });

  test('a tile legend accounts for every cell in the tile', () {
    for (final tile in blueprintTiles(plan)) {
      final counted = tile.legend.fold<int>(
        0,
        (sum, entry) => sum + entry.count,
      );
      expect(counted, tile.width * tile.height, reason: 'tile ${tile.index}');

      // Most-used first, which is the order the sheet prints them in.
      for (var i = 1; i < tile.legend.length; i++) {
        expect(
          tile.legend[i - 1].count,
          greaterThanOrEqualTo(tile.legend[i].count),
        );
      }
    }
  });

  test('the legend is per tile, not the whole picture', () {
    final tiles = blueprintTiles(plan);
    final whole = plan.blocks.length;
    for (final tile in tiles) {
      expect(tile.legend.length, lessThanOrEqualTo(whole));
      // Every entry must be a block the picture really uses.
      for (final entry in tile.legend) {
        expect(plan.blocks, contains(entry.block));
      }
    }
  });

  test('only the northern row of tiles has a reference row above it', () {
    final tiles = blueprintTiles(plan);

    expect(tiles[0].hasReferenceRow, isTrue);
    expect(tiles[1].hasReferenceRow, isTrue);
    // The southern row's north edge is the previous map, so there is no extra
    // row to build there.
    expect(tiles[2].hasReferenceRow, isFalse);
    expect(tiles[3].hasReferenceRow, isFalse);
  });

  test('the subtitle names the size, the version and the height range', () {
    final subtitle = blueprintSubtitle(plan, sourceName: 'cat.png');

    expect(subtitle, startsWith('cat.png'));
    expect(subtitle, contains('256 x 256 格'));
    expect(subtitle, contains('2 x 2 张地图'));
    expect(subtitle, contains('Minecraft ${plan.versionId}'));
    expect(subtitle, contains('Y ${plan.minHeight}..${plan.maxHeight}'));
  });

  test('the notes say where the reference row goes and how to line up', () {
    // These two are the only instructions a printed sheet carries, and both are
    // things a builder cannot work out from the grid alone.
    expect(
      blueprintReferenceNote(plan),
      contains('${plan.referenceRowHeight}'),
    );
    expect(blueprintAlignmentNote(), contains('64 + 128'));
  });

  test('a tile label reads as the sheet numbers it', () {
    final tiles = blueprintTiles(plan);
    expect(tileLabel(tiles[3]), '第 4 张 · 第 2 行 第 2 列');
  });

  test('a single-map picture has one tile and no tile paging', () {
    final one = buildTestResult().plan;
    final tiles = blueprintTiles(one);

    expect(tiles, hasLength(1));
    expect(tiles.single.hasReferenceRow, isTrue);
    expect(one.mapCount, 1);
  });
}
