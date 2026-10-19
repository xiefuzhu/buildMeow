import 'dart:typed_data';

import 'package:mapart_core/mapart_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The Sponge Schematic v2 writer.
///
/// Two things here cannot be eyeballed: the varint encoding, which the
/// specification defines only by linking to Sponge's Java, and the order the
/// cells are stored in, which is `x + z * Width + y * Width * Length` and is
/// easy to write down as something that looks right and is not.
void main() {
  /// A tiny hand-made structure, so the index arithmetic can be checked
  /// against a coordinate rather than against a round trip.
  Structure tiny() {
    const stone = BlockStateRef('minecraft:stone');
    const log = BlockStateRef('minecraft:oak_log', {'axis': 'y'});
    final structure = Structure(
      sizeX: 2,
      sizeY: 2,
      sizeZ: 3,
      palette: const [airBlockState, stone, log],
      cells: Int32List(2 * 2 * 3),
    );
    // (x=1, y=1, z=2) -> index 1 * (2*3) + 2 * 2 + 1 = 11
    structure.cells[11] = 1;
    // (x=0, y=1, z=0) -> index 1 * 6 + 0 + 0 = 6
    structure.cells[6] = 2;
    return structure;
  }

  Uint8List write(Structure structure) => writeSpongeSchematic(
    structure,
    dataVersion: 4790,
    name: '建喵 测试',
    author: '建喵!',
  );

  group('varint', () {
    test('encodes the way the specification\'s Java does', () {
      // One byte per seven bits, high bit set while more follow.
      Uint8List encode(int value) {
        final bytes = <int>[];
        var remaining = value;
        while (true) {
          if (remaining & ~0x7F == 0) {
            bytes.add(remaining);
            return Uint8List.fromList(bytes);
          }
          bytes.add((remaining & 0x7F) | 0x80);
          remaining >>>= 7;
        }
      }

      expect(encode(0), [0x00]);
      expect(encode(1), [0x01]);
      expect(encode(127), [0x7F]);
      expect(encode(128), [0x80, 0x01]);
      expect(encode(300), [0xAC, 0x02]);
      expect(encode(16383), [0xFF, 0x7F]);
      expect(encode(16384), [0x80, 0x80, 0x01]);
    });

    test('the file uses that encoding for every cell', () {
      final bytes = write(tiny());
      final root = readNbt(bytes).root;
      final data = (root['BlockData']! as NbtByteArray).value;
      // Twelve cells, eleven of them air, one stone, one log. Every index here
      // is under 128, so every varint is one byte.
      expect(data.length, 12);
      expect(data[11], 1, reason: 'stone at (1, 1, 2)');
      expect(data[6], 2, reason: 'log at (0, 1, 0)');
      expect(
        data.where((byte) => byte != 0).length,
        2,
        reason: 'nothing else is placed',
      );
    });
  });

  group('file', () {
    test('is gzipped and carries version 2 with the target data version', () {
      final bytes = write(tiny());
      expect(bytes.sublist(0, 2), [0x1F, 0x8B]);

      final root = readNbt(bytes).root;
      expect((root['Version']! as NbtInt).value, 2);
      expect((root['DataVersion']! as NbtInt).value, 4790);
      expect((root['Width']! as NbtShort).value, 2);
      expect((root['Height']! as NbtShort).value, 2);
      expect((root['Length']! as NbtShort).value, 3);
      expect((root['Offset']! as NbtIntArray).value, [0, 0, 0]);
    });

    test('PaletteMax is the palette size, as WorldEdit writes it', () {
      final root = readNbt(write(tiny())).root;
      final palette = root['Palette']! as NbtCompound;
      expect((root['PaletteMax']! as NbtInt).value, palette.length);
      expect((root['PaletteMax']! as NbtInt).value, 3);
    });

    test('the palette names block states the way the specification does', () {
      final root = readNbt(write(tiny())).root;
      final palette = root['Palette']! as NbtCompound;
      expect(palette.value.keys.toSet(), {
        'minecraft:air',
        'minecraft:stone',
        // Properties sorted by key, namespaced, no spaces.
        'minecraft:oak_log[axis=y]',
      });
      expect((palette['minecraft:air']! as NbtInt).value, 0);
    });

    test('reads back with the same palette and every block in place', () {
      final original = tiny();
      final read = readSpongeSchematic(write(original));

      expect(read.palette, original.palette);
      expect(read.cells, original.cells);
      expect(read.sizeX, 2);
      expect(read.sizeY, 2);
      expect(read.sizeZ, 3);
      expect(read.at(1, 1, 2), 1);
      expect(read.at(0, 1, 0), 2);
      expect(read.nonAirBlocks, 2);
    });

    test('a version 3 file reads too, so a re-export is not a dead end', () {
      // Version 3 moves the palette and the block data into a nested `Blocks`
      // compound and calls the array `Data`. Current WorldEdit writes that by
      // default, so a file that has been through the game comes back like this.
      final root = readNbt(write(tiny())).root;
      final v3 = NbtCompound({
        for (final entry in root.value.entries)
          if (entry.key != 'Palette' && entry.key != 'BlockData')
            entry.key: entry.key == 'Version' ? const NbtInt(3) : entry.value,
        'Blocks': NbtCompound({
          'Palette': root['Palette']!,
          'Data': root['BlockData']!,
          'BlockEntities': const NbtList([]),
        }),
      });

      final read = readSpongeSchematic(writeNbt(v3));
      expect(read.cells, tiny().cells);
      expect(read.palette, tiny().palette);
    });

    test('a file with no palette is rejected', () {
      expect(
        () => readSpongeSchematic(
          writeNbt(
            NbtCompound({
              'Version': const NbtInt(2),
              'Width': const NbtShort(1),
              'Height': const NbtShort(1),
              'Length': const NbtShort(1),
              'BlockData': NbtByteArray(Uint8List.fromList([0])),
            }),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('a block index outside the palette is rejected', () {
      expect(
        () => readSpongeSchematic(
          writeNbt(
            NbtCompound({
              'Version': const NbtInt(2),
              'Width': const NbtShort(1),
              'Height': const NbtShort(1),
              'Length': const NbtShort(1),
              'Palette': NbtCompound({'minecraft:air': const NbtInt(0)}),
              'BlockData': NbtByteArray(Uint8List.fromList([5])),
            }),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('block data that ends mid-varint is rejected', () {
      expect(
        () => readSpongeSchematic(
          writeNbt(
            NbtCompound({
              'Version': const NbtInt(2),
              'Width': const NbtShort(1),
              'Height': const NbtShort(1),
              'Length': const NbtShort(2),
              'Palette': NbtCompound({'minecraft:air': const NbtInt(0)}),
              // The second byte promises a continuation that never comes.
              'BlockData': NbtByteArray(Uint8List.fromList([0x00, 0x80])),
            }),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('a real map', () {
    test('round trips through the file with nothing lost', () {
      final plan = Pipeline.run(
        bands(128, 128),
        palette: Palette.select(loadColorTable(), '1.20'),
        mapsX: 1,
        mapsY: 1,
      ).plan(names: loadBlockNames());
      final structure = buildStructure(plan);
      final read = readSpongeSchematic(write(structure));

      expect(read.sizeX, structure.sizeX);
      expect(read.sizeY, structure.sizeY);
      expect(read.sizeZ, structure.sizeZ);
      expect(read.palette, structure.palette);
      expect(read.cells, structure.cells);
    });
  });
}
