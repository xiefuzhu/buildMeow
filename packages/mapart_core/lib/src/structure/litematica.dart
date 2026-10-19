import 'dart:typed_data';

import '../block_state_ref.dart';
import '../nbt/nbt_reader.dart';
import '../nbt/nbt_tag.dart';
import '../nbt/nbt_writer.dart';
import 'bit_array.dart';
import 'structure.dart';

/// The schematic container version this writes.
///
/// 6 is the format from 1.20.4 onwards. Litematica reads any file whose
/// `Version` is between 1 and its own `SCHEMATIC_VERSION` (7 in the 1.21.1
/// branch), and versions 6 and 7 have the same layout, so writing 6 is the
/// widest compatibility point: every Litematica from 1.20.4 on accepts it.
const int litematicaSchematicVersion = 6;

/// The `SubVersion` Litematica itself writes alongside version 6.
const int litematicaSchematicSubVersion = 1;

/// Everything the file's metadata carries.
class LitematicMetadata {
  const LitematicMetadata({
    required this.name,
    required this.author,
    this.description = '',
    this.created,
    this.modified,
  });

  final String name;
  final String author;
  final String description;

  /// Milliseconds since the Unix epoch, as Litematica stores them.
  final DateTime? created;
  final DateTime? modified;
}

/// Serialises a structure as a Litematica `.litematic`.
///
/// The layout was read out of Litematica's own sources rather than guessed at:
///
/// * root: `MinecraftDataVersion`, `Version`, `SubVersion`, `Metadata`,
///   `Regions`;
/// * region: `BlockStatePalette` (a list of `{Name, Properties?}`),
///   `BlockStates` (a **long array**), `TileEntities`, `Entities`,
///   `PendingBlockTicks`, `PendingFluidTicks`, `Position`, `Size`;
/// * `Position` and `Size` are `{x, y, z}` with lowercase keys, which is what
///   `NBTUtils.createBlockPosTag` writes in the 1.21 generation;
/// * the block array is Litematica's own packing — see [LitematicaBitArray];
/// * palette entry 0 is air;
/// * the whole thing is gzipped.
///
/// [dataVersion] is the Minecraft data version to stamp on the file. Writing the
/// target release's own value means a current Litematica does not run its
/// DataFixer over the palette, which would rename or drop blocks the fixer does
/// not know.
Uint8List writeLitematic(
  Structure structure, {
  required int dataVersion,
  required LitematicMetadata metadata,
  int version = litematicaSchematicVersion,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final created = metadata.created?.millisecondsSinceEpoch ?? now;
  final modified = metadata.modified?.millisecondsSinceEpoch ?? now;

  final bits = LitematicaBitArray.bitsFor(structure.palette.length);
  final array = LitematicaBitArray(bits, structure.volume);
  for (var i = 0; i < structure.cells.length; i++) {
    array.setAt(i, structure.cells[i]);
  }

  final region = NbtCompound({
    'BlockStatePalette': NbtList([
      for (final state in structure.palette) _blockStateTag(state),
    ]),
    'BlockStates': NbtLongArray(array.backing),
    'TileEntities': const NbtList([]),
    'Entities': const NbtList([]),
    'PendingBlockTicks': const NbtList([]),
    'PendingFluidTicks': const NbtList([]),
    'Position': _posTag(
      structure.originX,
      structure.originY,
      structure.originZ,
    ),
    'Size': _posTag(structure.sizeX, structure.sizeY, structure.sizeZ),
  });

  final root = NbtCompound({
    'MinecraftDataVersion': NbtInt(dataVersion),
    'Version': NbtInt(version),
    'SubVersion': NbtInt(litematicaSchematicSubVersion),
    'Metadata': NbtCompound({
      'Name': NbtString(metadata.name),
      'Author': NbtString(metadata.author),
      'Description': NbtString(metadata.description),
      'RegionCount': const NbtInt(1),
      'TotalVolume': NbtInt(structure.volume),
      'TotalBlocks': NbtInt(structure.nonAirBlocks),
      'EnclosingSize': _posTag(
        structure.sizeX,
        structure.sizeY,
        structure.sizeZ,
      ),
      'TimeCreated': NbtLong(created),
      'TimeModified': NbtLong(modified),
    }),
    'Regions': NbtCompound({'mapart': region}),
  });

  return writeNbt(root);
}

/// Reads a `.litematic` back.
///
/// Written because the acceptance criterion is a round trip: a file this
/// project writes has to be readable before it is worth loading into the game,
/// and the reader is the only thing that can check the bit packing and the
/// palette ordering without a copy of Minecraft.
///
/// Only the parts this project writes are understood. A file Litematica saved
/// from a world selection carries tile entities, entities and pending ticks, and
/// those are ignored rather than preserved — reading is for verification, not
/// for editing.
Structure readLitematic(Uint8List bytes) {
  final root = readNbt(bytes).root;

  final version = (root['Version'] as NbtInt?)?.value;
  if (version == null) {
    throw const FormatException('not a litematic file: no Version tag');
  }
  if (version < 1 || version > litematicaSchematicVersion) {
    throw FormatException(
      'litematic container version $version is newer than the $litematicaSchematicVersion '
      'this reader understands',
    );
  }

  final regions = root['Regions'];
  if (regions is! NbtCompound || regions.value.isEmpty) {
    throw const FormatException('litematic file has no regions');
  }
  // Litematica names its regions after the selection boxes. This project writes
  // exactly one, so anything else is a file it did not write; reading the first
  // is still the useful behaviour.
  final region = regions.value.values.first;
  if (region is! NbtCompound) {
    throw const FormatException('litematic region is not a compound');
  }

  final size = _readPos(region['Size']);
  final position = _readPos(region['Position']);

  final paletteTag = region['BlockStatePalette'];
  if (paletteTag is! NbtList) {
    throw const FormatException('litematic region has no block state palette');
  }
  final palette = <BlockStateRef>[
    for (final tag in paletteTag.value) _readBlockState(tag),
  ];
  if (palette.isEmpty || palette.first != airBlockState) {
    throw const FormatException(
      'litematic palette entry 0 must be air; every block would otherwise be '
      'shifted by one',
    );
  }

  final blockStates = region['BlockStates'];
  if (blockStates is! NbtLongArray) {
    throw const FormatException('litematic region has no BlockStates array');
  }

  final volume = size.x * size.y * size.z;
  final bits = LitematicaBitArray.bitsFor(palette.length);
  final expected = LitematicaBitArray.longCountFor(volume, bits);
  if (blockStates.value.length != expected) {
    throw FormatException(
      'litematic BlockStates has ${blockStates.value.length} longs, but '
      '${palette.length} palette entries over $volume cells need $expected',
    );
  }
  final array = LitematicaBitArray(bits, volume, blockStates.value);
  final cells = Int32List(volume);
  for (var i = 0; i < volume; i++) {
    final index = array.getAt(i);
    if (index >= palette.length) {
      throw FormatException(
        'litematic block ${array.getAt(i)} is outside the palette',
      );
    }
    cells[i] = index;
  }

  return Structure(
    sizeX: size.x,
    sizeY: size.y,
    sizeZ: size.z,
    palette: List.unmodifiable(palette),
    cells: cells,
    originX: position.x,
    originY: position.y,
    originZ: position.z,
  );
}

/// The metadata a `.litematic` carries, read back for the round-trip tests.
LitematicMetadata readLitematicMetadata(Uint8List bytes) {
  final metadata = readNbt(bytes).root['Metadata'];
  if (metadata is! NbtCompound) {
    throw const FormatException('litematic file has no Metadata');
  }
  String text(String key) => (metadata[key] as NbtString?)?.value ?? '';
  return LitematicMetadata(
    name: text('Name'),
    author: text('Author'),
    description: text('Description'),
    created: DateTime.fromMillisecondsSinceEpoch(
      (metadata['TimeCreated'] as NbtLong?)?.value ?? 0,
    ),
    modified: DateTime.fromMillisecondsSinceEpoch(
      (metadata['TimeModified'] as NbtLong?)?.value ?? 0,
    ),
  );
}

NbtCompound _blockStateTag(BlockStateRef state) => NbtCompound({
  'Name': NbtString(state.namespacedId),
  // Litematica omits the tag entirely for a block with no properties, and
  // `NbtHelper.toBlockState` then uses the block's default state.
  if (state.properties.isNotEmpty)
    'Properties': NbtCompound({
      for (final entry in state.properties.entries)
        entry.key: NbtString(entry.value),
    }),
});

BlockStateRef _readBlockState(NbtTag tag) {
  if (tag is! NbtCompound) {
    throw const FormatException('a palette entry is not a compound');
  }
  final name = (tag['Name'] as NbtString?)?.value;
  if (name == null) {
    throw const FormatException('a palette entry has no Name');
  }
  final properties = tag['Properties'];
  return BlockStateRef(
    name,
    properties is NbtCompound
        ? {
            for (final entry in properties.value.entries)
              entry.key: (entry.value as NbtString).value,
          }
        : const {},
  );
}

NbtCompound _posTag(int x, int y, int z) =>
    NbtCompound({'x': NbtInt(x), 'y': NbtInt(y), 'z': NbtInt(z)});

({int x, int y, int z}) _readPos(NbtTag? tag) {
  if (tag is! NbtCompound) {
    throw const FormatException('expected an {x, y, z} compound');
  }
  int read(String key) {
    final value = tag[key];
    if (value is! NbtInt) {
      throw FormatException('an {x, y, z} compound is missing "$key"');
    }
    return value.value;
  }

  return (x: read('x'), y: read('y'), z: read('z'));
}
