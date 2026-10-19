import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../block_state_ref.dart';
import '../map_plan.dart';

/// How much of the build a schematic contains.
enum ExportShape {
  /// One block per column, at its solved height: the staircase itself.
  ///
  /// What a projection is for — you build a floor of your own, then place the
  /// surface blocks against the ghost outline. A single map is about 16.5k
  /// blocks, so the file stays tiny and Litematica stays responsive.
  surface,

  /// Every layer from the lowest one up to each column's height.
  ///
  /// What the build looks like when it is finished, and what you would get if
  /// you copied an existing mapart. It is also enormously bigger: a single map
  /// with a 65-layer span is around half a million blocks, and a 5x5 build is
  /// tens of millions, which Litematica will struggle to render.
  solid,
}

/// A cuboid of block states, laid out the way both schematic formats store one.
///
/// The cell order is `y * (sizeX * sizeZ) + z * sizeX + x`, which is what
/// Litematica's container uses and, spelled differently, what the Sponge
/// specification's `x + z * Width + y * Width * Length` also means. Writing it
/// down once here is what lets the two writers share a model.
@immutable
class Structure {
  Structure({
    required this.sizeX,
    required this.sizeY,
    required this.sizeZ,
    required this.palette,
    required this.cells,
    this.originX = 0,
    this.originY = 0,
    this.originZ = 0,
  }) : assert(cells.length == sizeX * sizeY * sizeZ);

  final int sizeX;
  final int sizeY;
  final int sizeZ;

  /// The block states, **index 0 being air**.
  ///
  /// Not a convention of ours: Litematica registers air as id 0 when it builds
  /// a container, and its palette reader skips the file's entry 0 when that
  /// entry is air. A file whose entry 0 is anything else reads back with every
  /// block shifted by one.
  final List<BlockStateRef> palette;

  /// One palette index per cell.
  final Int32List cells;

  /// The region's position in the schematic's own coordinates.
  ///
  /// Zero, so the schematic's origin is the north-west corner of the reference
  /// row and the map's own north edge is one block south of it. The vertical
  /// coordinate is not the build's world Y: the structure starts at its lowest
  /// layer, and where that lands in the world is the placement's business.
  final int originX;
  final int originY;
  final int originZ;

  int get volume => sizeX * sizeY * sizeZ;

  int indexOf(int x, int y, int z) => y * (sizeX * sizeZ) + z * sizeX + x;

  int at(int x, int y, int z) => cells[indexOf(x, y, z)];

  bool get isEmpty => cells.every((index) => index == 0);

  int get nonAirBlocks {
    var count = 0;
    for (final index in cells) {
      if (index != 0) count++;
    }
    return count;
  }

  /// How many distinct block states the structure places, air excluded.
  int get paletteBlocks {
    final used = <int>{};
    for (final index in cells) {
      if (index != 0) used.add(index);
    }
    return used.length;
  }

  /// The structure's extent as `(sizeX, sizeY, sizeZ)`, for the metadata.
  ({int x, int y, int z}) get enclosingSize => (x: sizeX, y: sizeY, z: sizeZ);

  @override
  String toString() =>
      'Structure(${sizeX}x${sizeY}x$sizeZ, ${palette.length} palette entries, '
      '$nonAirBlocks blocks)';
}

/// The air state both formats' palettes have to start with.
const BlockStateRef airBlockState = BlockStateRef('minecraft:air');

/// Turns a plan into the cuboid a schematic file can hold.
///
/// The layout, in the schematic's own coordinates:
///
/// * `x` runs west to east, the map's own left-to-right.
/// * `z` runs north to south. With [includeReferenceRow], `z = 0` is the extra
///   reference row and the map's first row is `z = 1`; without it the map starts
///   at `z = 0`.
/// * `y = 0` is the lowest layer the build has, so the structure is only as
///   tall as the staircase actually is rather than as tall as the world.
///
/// The reference row is built out of the same blocks as the map's northernmost
/// row, one per column. Its colour is never seen — it sits outside every map —
/// but its *height* is what decides the shade of the map's first row, so it has
/// to be there.
Structure buildStructure(
  MapPlan plan, {
  ExportShape shape = ExportShape.surface,
  bool includeReferenceRow = true,
}) {
  final baseY = includeReferenceRow
      ? math.min(plan.minHeight, plan.referenceRowHeight)
      : plan.minHeight;
  final topY = includeReferenceRow
      ? math.max(plan.maxHeight, plan.referenceRowHeight)
      : plan.maxHeight;
  final sizeY = topY - baseY + 1;
  final sizeX = plan.width;
  final sizeZ = plan.height + (includeReferenceRow ? 1 : 0);
  final sizeLayer = sizeX * sizeZ;
  final rowOffset = includeReferenceRow ? 1 : 0;

  // The palette, air first. Deduplicated by block state: two entries of the
  // plan can name the same state, and a palette with it twice would waste bits
  // per entry for every block in the build.
  final palette = <BlockStateRef>[airBlockState];
  final paletteIndex = <String, int>{airBlockState.toBlockStateString(): 0};
  final planToPalette = Int32List(plan.blocks.length);
  for (var i = 0; i < plan.blocks.length; i++) {
    final state = BlockStateRef.parse(plan.blocks[i].blockState);
    final key = state.toBlockStateString();
    final index = paletteIndex.putIfAbsent(key, () {
      palette.add(state);
      return palette.length - 1;
    });
    planToPalette[i] = index;
  }

  final cells = Int32List(sizeX * sizeY * sizeZ);
  final surfaceY = Int32List(plan.pixelCount);
  for (var y = 0; y < plan.height; y++) {
    for (var x = 0; x < plan.width; x++) {
      final p = y * plan.width + x;
      surfaceY[p] = plan.heightAt(x, y) - baseY;
    }
  }

  for (var y = 0; y < plan.height; y++) {
    for (var x = 0; x < plan.width; x++) {
      final p = y * plan.width + x;
      final index = planToPalette[plan.blockIndexAt(x, y)];
      final top = surfaceY[p];
      final bottom = shape == ExportShape.solid ? 0 : top;
      final z = y + rowOffset;
      // Walking up one layer moves one whole Z slice along, so the cell index
      // advances by a constant. Recomputing it per cell cost more than the
      // assignment did: a 5x5 solid build is ninety million cells.
      var cell = (bottom * sizeZ + z) * sizeX + x;
      for (var localY = bottom; localY <= top; localY++) {
        cells[cell] = index;
        cell += sizeLayer;
      }
    }
  }

  if (includeReferenceRow) {
    // One row of the same blocks as the map's northern edge, at the reference
    // row's own height.
    final referenceTop = plan.referenceRowHeight - baseY;
    final bottom = shape == ExportShape.solid ? 0 : referenceTop;
    for (var x = 0; x < plan.width; x++) {
      final index = planToPalette[plan.blockIndexAt(x, 0)];
      var cell = bottom * sizeLayer + x;
      for (var localY = bottom; localY <= referenceTop; localY++) {
        cells[cell] = index;
        cell += sizeLayer;
      }
    }
  }

  return Structure(
    sizeX: sizeX,
    sizeY: sizeY,
    sizeZ: sizeZ,
    palette: List.unmodifiable(palette),
    cells: cells,
  );
}

/// The absolute Y a structure's layer `y` corresponds to, given the plan it was
/// built from.
///
/// The writers do not need it — the file stores relative layers — but the
/// blueprint sheets do, because "this block sits at Y 68" is the useful thing to
/// print.
int absoluteYOf(MapPlan plan, int localY, {bool includeReferenceRow = true}) =>
    localY +
    (includeReferenceRow
        ? math.min(plan.minHeight, plan.referenceRowHeight)
        : plan.minHeight);
