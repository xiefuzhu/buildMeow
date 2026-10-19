import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mapart_core/mapart_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The acceptance criterion for the exports: a structure read back out of the
/// file has to reproduce the preview **pixel for pixel**.
///
/// Nothing here trusts the plan's own bookkeeping. The colours are rebuilt from
/// what the file actually contains — the palette states, the cells, and the
/// shade rule — so a wrong column height, a lost reference row, a block shifted
/// along the palette or a step sign flipped all show up as a differing pixel
/// rather than as a test that passes because it compared a value to itself.
void main() {
  late Palette palette;
  late MapPlan plan;

  setUpAll(() {
    palette = Palette.select(loadColorTable(), '1.20');
    plan = Pipeline.run(
      bands(128, 128),
      palette: palette,
      mapsX: 1,
      mapsY: 1,
    ).plan(names: loadBlockNames());
  });

  /// The plan's own picture, which is what the preview draws.
  RgbaImage preview() => renderPlanMap(plan: plan);

  for (final shape in ExportShape.values) {
    group('${shape.name} export', () {
      test('the columns come back at the heights the solver chose', () {
        final structure = _roundTrip(buildStructure(plan, shape: shape));
        final heights = _heightsOf(structure, plan);

        expect(heights.reference, plan.referenceRowHeight);
        for (var y = 0; y < plan.height; y++) {
          for (var x = 0; x < plan.width; x++) {
            expect(
              heights.map[y * plan.width + x],
              plan.heightAt(x, y),
              reason: 'column ($x, $y)',
            );
          }
        }
      });

      test('the file renders pixel for pixel what the preview shows', () {
        final structure = _roundTrip(buildStructure(plan, shape: shape));
        final rebuilt = _renderFromStructure(structure, plan);

        expect(rebuilt.width, preview().width);
        expect(rebuilt.height, preview().height);
        expect(
          rebuilt.bytes,
          preview().bytes,
          reason: 'the exported structure must reproduce the preview exactly',
        );
      });
    });
  }

  test('both formats produce the same picture', () {
    final structure = buildStructure(plan);
    final fromLitematic = _renderFromStructure(
      readLitematic(_writeLitematic(structure)),
      plan,
    );
    final fromSchem = _renderFromStructure(
      readSpongeSchematic(
        writeSpongeSchematic(structure, dataVersion: plan.dataVersion),
      ),
      plan,
    );
    expect(fromSchem.bytes, fromLitematic.bytes);
  });

  test('the reference row is load-bearing, not decoration', () {
    // Shift the reference row by one block and the map's first row changes
    // shade. That is the whole reason the export carries a row the picture does
    // not contain.
    //
    // A gradient is used rather than the bands: its first row is a mid grey, so
    // the solver steps neither up nor down there and a one-block error moves it
    // in either direction. Against a picture whose first row already sits at an
    // extreme, only one of the two directions would show, and the test would be
    // proving less than it looks.
    final soft = Pipeline.run(
      gradient(128, 128),
      palette: palette,
      mapsX: 1,
      mapsY: 1,
    ).plan(names: loadBlockNames());
    final structure = _roundTrip(buildStructure(soft));
    final heights = _heightsOf(structure, soft);
    final asBuilt = _renderFromHeights(structure, soft, heights);
    final expected = renderPlanMap(plan: soft);

    expect(asBuilt.bytes, expected.bytes);
    expect(
      _renderFromHeights(
        structure,
        soft,
        (map: heights.map, reference: heights.reference + 1),
      ).bytes,
      isNot(expected.bytes),
      reason: 'a reference row one block too high must change row 0',
    );
    expect(
      _renderFromHeights(
        structure,
        soft,
        (map: heights.map, reference: heights.reference - 1),
      ).bytes,
      isNot(expected.bytes),
      reason: 'a reference row one block too low must change row 0',
    );
  });

  test('a map with no staircase still exports and re-renders', () {
    // The texture-average palette builds one flat layer, which is the other
    // kind of picture this app makes. The round trip has to hold there too.
    final flat = Pipeline.run(
      gradient(128, 128),
      palette: loadAppPalette(),
      mapsX: 1,
      mapsY: 1,
    ).plan(names: loadBlockNames());
    final structure = _roundTrip(buildStructure(flat));

    expect(flat.maxHeight - flat.minHeight, 0);
    expect(
      _renderFromStructure(structure, flat).bytes,
      renderPlanMap(plan: flat).bytes,
    );
  });

  test('a two-map build exports as one continuous staircase', () {
    final wide = Pipeline.run(
      bands(256, 128),
      palette: palette,
      mapsX: 2,
      mapsY: 1,
    ).plan(names: loadBlockNames());
    final structure = _roundTrip(buildStructure(wide));

    expect(structure.sizeX, 256);
    expect(_renderFromStructure(structure, wide).bytes, renderPlanMap(plan: wide).bytes);
    // Heights are continuous across the seam: the step between the last column
    // of the first map and the first column of the second is legal.
    for (var y = 0; y < wide.height; y++) {
      final left = wide.heightAt(127, y);
      final right = wide.heightAt(128, y);
      expect((right - left).abs(), lessThanOrEqualTo(1));
    }
  });
}

/// Writes a `.litematic` and reads it back, so the tests exercise the file
/// rather than the in-memory structure.
Structure _roundTrip(Structure structure) => readLitematic(
  _writeLitematic(structure),
);

Uint8List _writeLitematic(Structure structure) => writeLitematic(
  structure,
  dataVersion: 4790,
  metadata: const LitematicMetadata(name: 'self check', author: '建喵!'),
);

/// The absolute height of every map column, and of the reference row, read back
/// out of the structure.
({Int32List map, int reference}) _heightsOf(Structure structure, MapPlan plan) {
  final baseY = _baseY(plan);
  final map = Int32List(plan.pixelCount);
  for (var y = 0; y < plan.height; y++) {
    for (var x = 0; x < plan.width; x++) {
      map[y * plan.width + x] = _columnTop(structure, x, y + 1) + baseY;
    }
  }
  return (
    map: map,
    reference: _columnTop(structure, 0, 0) + baseY,
  );
}

int _columnTop(Structure structure, int x, int z) {
  for (var localY = structure.sizeY - 1; localY >= 0; localY--) {
    if (structure.at(x, localY, z) != 0) return localY;
  }
  throw StateError('column (x=$x, z=$z) is empty in the exported structure');
}

/// Rebuilds the map picture from the structure alone, plus the shade rule.
RgbaImage _renderFromStructure(Structure structure, MapPlan plan) =>
    _renderFromHeights(structure, plan, _heightsOf(structure, plan));

RgbaImage _renderFromHeights(
  Structure structure,
  MapPlan plan,
  ({Int32List map, int reference}) heights,
) {
  final byState = {
    for (final block in plan.blocks) block.blockState: block,
  };
  final out = RgbaImage(plan.width, plan.height);
  for (var y = 0; y < plan.height; y++) {
    for (var x = 0; x < plan.width; x++) {
      final p = y * plan.width + x;
      final north = y == 0
          ? heights.reference
          : heights.map[(y - 1) * plan.width + x];
      final tier = ShadeTier.fromHeightDelta(heights.map[p] - north);
      final z = y + 1;
      final localY = _columnTop(structure, x, z);
      final state = structure.palette[structure.at(x, localY, z)];
      final block = byState[state.toBlockStateString()];
      if (block == null) {
        throw StateError('the structure places $state, which is not in the plan');
      }
      out.setRgb(x, y, block.tone(tier));
    }
  }
  return out;
}

int _baseY(MapPlan plan) =>
    math.min(plan.minHeight, plan.referenceRowHeight);
