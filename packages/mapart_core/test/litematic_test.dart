import 'dart:typed_data';

import 'package:mapart_core/mapart_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The `.litematic` writer.
///
/// The packing is the part that cannot be checked by eye: an entry that straddles
/// a long boundary is either placed the way Litematica places it or the file
/// loads as noise, and nothing in this project would notice. So the bit array is
/// tested against hand-computed long values taken from Litematica's own
/// algorithm, and the file is tested by reading it back.
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

  group('bit array', () {
    test('bits per entry follows Litematica, including its minimum of two', () {
      expect(LitematicaBitArray.bitsFor(1), 2);
      expect(LitematicaBitArray.bitsFor(2), 2);
      expect(LitematicaBitArray.bitsFor(3), 2);
      expect(LitematicaBitArray.bitsFor(4), 2);
      expect(LitematicaBitArray.bitsFor(5), 3);
      expect(LitematicaBitArray.bitsFor(9), 4);
      expect(LitematicaBitArray.bitsFor(17), 5);
      expect(LitematicaBitArray.bitsFor(33), 6);
      expect(LitematicaBitArray.bitsFor(61), 6);
      expect(LitematicaBitArray.bitsFor(65), 7);
    });

    test('the array is as long as Litematica rounds it up to', () {
      // roundUp(size * bits, 64) / 64, with at least one long.
      expect(LitematicaBitArray.longCountFor(0, 2), 1);
      expect(LitematicaBitArray.longCountFor(1, 2), 1);
      expect(LitematicaBitArray.longCountFor(32, 2), 1);
      expect(LitematicaBitArray.longCountFor(33, 2), 2);
      expect(LitematicaBitArray.longCountFor(128 * 129, 6), 1548);
    });

    test('entries pack back to back, little end first within a long', () {
      // Four entries of three bits each fill the low twelve bits of one long:
      // 0, 1, 2, 3 gives 0b011_010_001_000.
      final array = LitematicaBitArray(3, 4);
      for (var i = 0; i < 4; i++) {
        array.setAt(i, i);
      }
      expect(array.backing.length, 1);
      expect(array.backing[0], 0 + (1 << 3) + (2 << 6) + (3 << 9));
      for (var i = 0; i < 4; i++) {
        expect(array.getAt(i), i);
      }
    });

    test('a value too wide for its slot is masked, not corrupted', () {
      // Litematica masks the value the same way, so a caller that passes an
      // out-of-range palette index gets the low bits rather than an entry that
      // spills into its neighbour.
      final array = LitematicaBitArray(2, 3);
      array.setAt(0, 0xFF);
      array.setAt(1, 2);
      expect(array.getAt(0), 3);
      expect(array.getAt(1), 2);
      expect(array.backing[0], 3 + (2 << 2));
    });

    test('an entry that straddles a long boundary lands where Litematica puts it', () {
      // Three bits per entry: entry 21 starts at bit 63, so its low bit is the
      // top bit of long 0 and its other two bits are the bottom of long 1.
      final array = LitematicaBitArray(3, 22);
      expect(array.backing.length, 2);
      array.setAt(21, 5); // 0b101
      expect(array.backing[0], -9223372036854775808);
      expect(array.backing[1], 2);
      expect(array.getAt(21), 5);
    });

    test('every entry survives a round trip at every width', () {
      // A palette of 61 entries takes six bits, which divides 64 badly enough
      // that most entries cross a boundary.
      for (final bits in [2, 3, 5, 6, 7, 9]) {
        final size = 300;
        final array = LitematicaBitArray(bits, size);
        final mask = (1 << bits) - 1;
        for (var i = 0; i < size; i++) {
          array.setAt(i, (i * 7 + 3) & mask);
        }
        for (var i = 0; i < size; i++) {
          expect(array.getAt(i), (i * 7 + 3) & mask, reason: 'bits=$bits i=$i');
        }
      }
    });
  });

  group('structure', () {
    test('is a staircase one block thick, with air at palette index 0', () {
      final structure = buildStructure(plan);

      expect(structure.palette.first, airBlockState);
      expect(structure.sizeX, 128);
      expect(structure.sizeY, plan.blockHeightSpan);
      // The reference row takes one extra Z slice.
      expect(structure.sizeZ, 129);
      expect(structure.nonAirBlocks, 128 * 129);
      expect(structure.paletteBlocks, plan.blocks.length);
    });

    test('the map sits one slice south of the reference row', () {
      final structure = buildStructure(plan);
      final baseY = plan.minHeight < plan.referenceRowHeight
          ? plan.minHeight
          : plan.referenceRowHeight;

      for (final (x, y) in [(0, 0), (5, 7), (127, 127)]) {
        final localY = plan.heightAt(x, y) - baseY;
        final state = structure.palette[structure.at(x, localY, y + 1)];
        expect(state.toBlockStateString(), plan.blockAt(x, y).blockState);
      }
      // And the reference row, at its own height, in slice 0.
      final referenceY = plan.referenceRowHeight - baseY;
      for (final x in [0, 64, 127]) {
        final state = structure.palette[structure.at(x, referenceY, 0)];
        expect(state.toBlockStateString(), plan.blockAt(x, 0).blockState);
      }
    });

    test('leaving the reference row out shortens the schematic', () {
      final withRow = buildStructure(plan);
      final without = buildStructure(plan, includeReferenceRow: false);

      expect(without.sizeZ, 128);
      expect(without.nonAirBlocks, 128 * 128);
      expect(without.sizeX, withRow.sizeX);
      // The map's own first row moves from slice 1 to slice 0.
      for (final x in [0, 64, 127]) {
        final localY = plan.heightAt(x, 0) - _baseY(plan);
        expect(
          without.palette[without.at(x, localY, 0)].toBlockStateString(),
          plan.blockAt(x, 0).blockState,
        );
      }
    });

    test('a solid structure fills every column down to the lowest layer', () {
      final surface = buildStructure(plan);
      final solid = buildStructure(plan, shape: ExportShape.solid);

      expect(solid.sizeX, surface.sizeX);
      expect(solid.sizeY, surface.sizeY);
      expect(solid.sizeZ, surface.sizeZ);
      expect(solid.nonAirBlocks, greaterThan(surface.nonAirBlocks));

      // The top of every column is unchanged; the volume below it is filled.
      final baseY = _baseY(plan);
      for (final (x, y) in [(0, 0), (31, 64), (127, 127)]) {
        final top = plan.heightAt(x, y) - baseY;
        final z = y + 1;
        expect(solid.at(x, top, z), surface.at(x, top, z));
        for (var localY = 0; localY < top; localY++) {
          expect(
            solid.at(x, localY, z),
            isNot(0),
            reason: 'column ($x, $y) should be filled at layer $localY',
          );
        }
      }
      // Air above the staircase stays air: the top of the structure is only
      // occupied where a column actually reaches it.
      final topOfColumn = plan.heightAt(0, 0) - baseY;
      if (topOfColumn + 1 < solid.sizeY) {
        expect(solid.at(0, topOfColumn + 1, 1), 0);
      }
    });
  });

  group('file', () {
    Uint8List write({ExportShape shape = ExportShape.surface}) => writeLitematic(
      buildStructure(plan, shape: shape),
      dataVersion: 4790,
      metadata: const LitematicMetadata(
        name: '建喵 测试',
        author: '建喵!',
        description: 'surface',
      ),
    );

    test('is gzipped and says the version Litematica reads', () {
      final bytes = write();
      expect(bytes.sublist(0, 2), [0x1F, 0x8B]);

      final root = readNbt(bytes).root;
      expect((root['Version']! as NbtInt).value, litematicaSchematicVersion);
      expect((root['MinecraftDataVersion']! as NbtInt).value, 4790);
      expect((root['SubVersion']! as NbtInt).value, isNonZero);

      final metadata = root['Metadata']! as NbtCompound;
      expect((metadata['Name']! as NbtString).value, '建喵 测试');
      expect((metadata['Author']! as NbtString).value, '建喵!');
      expect((metadata['RegionCount']! as NbtInt).value, 1);
      expect((metadata['TotalVolume']! as NbtInt).value, 128 * plan.blockHeightSpan * 129);
      expect(
        (metadata['EnclosingSize']! as NbtCompound)['z'],
        NbtInt(129),
      );

      final regions = root['Regions']! as NbtCompound;
      expect(regions.value.keys, ['mapart']);
      final region = regions['mapart']! as NbtCompound;
      // Position and Size are lowercase {x, y, z} in this generation of
      // Litematica, and the reader rejects anything else.
      expect((region['Position']! as NbtCompound)['x'], const NbtInt(0));
      expect((region['Size']! as NbtCompound)['z'], const NbtInt(129));
      expect(region['BlockStates'], isA<NbtLongArray>());
      expect(region['TileEntities'], isA<NbtList>());
      expect(region['PendingFluidTicks'], isA<NbtList>());
    });

    test('reads back with the same palette and every block in place', () {
      final original = buildStructure(plan);
      final read = readLitematic(write());

      expect(read.palette, original.palette);
      expect(read.sizeX, original.sizeX);
      expect(read.sizeY, original.sizeY);
      expect(read.sizeZ, original.sizeZ);
      expect(read.originX, original.originX);
      expect(read.originY, original.originY);
      expect(read.originZ, original.originZ);
      expect(read.cells, original.cells);
      expect(read.nonAirBlocks, original.nonAirBlocks);
    });

    test('a solid file reads back too, and keeps its block count', () {
      final original = buildStructure(plan, shape: ExportShape.solid);
      final read = readLitematic(write(shape: ExportShape.solid));
      expect(read.cells, original.cells);
      expect(read.nonAirBlocks, original.nonAirBlocks);
    });

    test('the metadata comes back', () {
      final metadata = readLitematicMetadata(write());
      expect(metadata.name, '建喵 测试');
      expect(metadata.author, '建喵!');
      expect(metadata.description, 'surface');
      expect(metadata.created, isNotNull);
      expect(metadata.modified, isNotNull);
    });

    test('a file whose palette does not start with air is rejected', () {
      // The failure this guards against is silent: Litematica would read every
      // block one place along the palette.
      final bytes = write();
      final root = readNbt(bytes).root;
      final regions = root['Regions']! as NbtCompound;
      final region = regions['mapart']! as NbtCompound;
      final palette = (region['BlockStatePalette']! as NbtList).value;
      palette[0] = NbtCompound({'Name': const NbtString('minecraft:stone')});
      final broken = writeNbt(
        NbtCompound({
          for (final entry in root.value.entries)
            entry.key: entry.key == 'Regions'
                ? NbtCompound({
                    'mapart': NbtCompound({
                      for (final e in region.value.entries)
                        e.key: e.key == 'BlockStatePalette'
                            ? NbtList(palette)
                            : e.value,
                    }),
                  })
                : entry.value,
        }),
      );
      expect(() => readLitematic(broken), throwsA(isA<FormatException>()));
    });

    test('a BlockStates array of the wrong length is rejected', () {
      final bytes = write();
      final root = readNbt(bytes).root;
      final regions = root['Regions']! as NbtCompound;
      final region = regions['mapart']! as NbtCompound;
      final longs = (region['BlockStates']! as NbtLongArray).value;
      final short = NbtCompound({
        for (final entry in region.value.entries)
          entry.key: entry.key == 'BlockStates'
              ? NbtLongArray(longs.sublist(0, longs.length - 1))
              : entry.value,
      });
      final broken = writeNbt(
        NbtCompound({
          for (final entry in root.value.entries)
            entry.key: entry.key == 'Regions'
                ? NbtCompound({'mapart': short})
                : entry.value,
        }),
      );
      expect(() => readLitematic(broken), throwsA(isA<FormatException>()));
    });

    test('a file with no Version is rejected rather than guessed at', () {
      expect(
        () => readLitematic(writeNbt(NbtCompound({'Regions': NbtCompound()}))),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

int _baseY(MapPlan plan) =>
    plan.minHeight < plan.referenceRowHeight
    ? plan.minHeight
    : plan.referenceRowHeight;
