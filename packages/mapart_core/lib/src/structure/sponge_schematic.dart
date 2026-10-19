import 'dart:typed_data';

import '../block_state_ref.dart';
import '../nbt/nbt_reader.dart';
import '../nbt/nbt_tag.dart';
import '../nbt/nbt_writer.dart';
import 'structure.dart';

/// The Sponge Schematic format version this writes.
///
/// Version 2 rather than 3: it is the one WorldEdit has read for longest, and
/// the version-3 layout moves the palette and block data into a nested `Blocks`
/// compound that older readers do not look for. Nothing this project needs to
/// store is missing from 2.
const int spongeSchematicVersion = 2;

/// Serialises a structure as a Sponge Schematic version 2 `.schem`.
///
/// Field by field against the specification, with the two places WorldEdit's
/// own writer settles an ambiguity taken from `SpongeSchematicV2Writer.java`:
///
/// * `Version`, `DataVersion`, `Width`/`Height`/`Length` as **shorts**,
///   `Offset`, `PaletteMax`, `Palette`, `BlockData`, `BlockEntities`,
///   `Metadata`;
/// * `BlockData` is one **varint** per cell, indexed
///   `x + z * Width + y * Width * Length`;
/// * `PaletteMax` is the palette's *size*. The specification calls it "the max
///   index - 1", which is not what WorldEdit writes and not what its reader
///   looks at, so the count is what goes in;
/// * the whole file is gzipped.
Uint8List writeSpongeSchematic(
  Structure structure, {
  required int dataVersion,
  String name = '',
  String author = '',
  DateTime? date,
}) {
  final blockData = _packVarInts(structure.cells);

  final root = NbtCompound({
    'Version': const NbtInt(spongeSchematicVersion),
    'DataVersion': NbtInt(dataVersion),
    'Metadata': NbtCompound({
      if (name.isNotEmpty) 'Name': NbtString(name),
      if (author.isNotEmpty) 'Author': NbtString(author),
      'Date': NbtLong((date ?? DateTime.now()).millisecondsSinceEpoch),
    }),
    'Width': NbtShort(structure.sizeX),
    'Height': NbtShort(structure.sizeY),
    'Length': NbtShort(structure.sizeZ),
    // The offset of the region's minimum corner from the copy origin. Both are
    // the same point here, so it is zero, which is what WorldEdit writes when
    // the selection starts at the origin.
    'Offset': NbtIntArray(Int32List.fromList([0, 0, 0])),
    'PaletteMax': NbtInt(structure.palette.length),
    'Palette': NbtCompound({
      for (var i = 0; i < structure.palette.length; i++)
        structure.palette[i].toBlockStateString(): NbtInt(i),
    }),
    'BlockData': NbtByteArray(blockData),
    'BlockEntities': const NbtList([]),
  });

  return writeNbt(root);
}

/// Reads a Sponge Schematic back, version 2 or 3.
///
/// Version 3 is accepted as well because it is what a current WorldEdit writes
/// by default, so a file this app exported, round-tripped through the game and
/// re-exported would otherwise be unreadable to its own verification. The two
/// differ only in where the palette and block data live.
Structure readSpongeSchematic(Uint8List bytes) {
  final root = readNbt(bytes).root;

  final version = (root['Version'] as NbtInt?)?.value ?? 1;
  if (version > 3) {
    throw FormatException('unsupported Sponge schematic version $version');
  }

  final width = _readShort(root['Width']);
  final height = _readShort(root['Height']);
  final length = _readShort(root['Length']);

  final NbtCompound holder;
  if (version >= 3) {
    final blocks = root['Blocks'];
    if (blocks is! NbtCompound) {
      throw const FormatException('a version 3 schematic needs a Blocks tag');
    }
    holder = blocks;
  } else {
    holder = root;
  }

  final paletteTag = holder['Palette'];
  if (paletteTag is! NbtCompound) {
    throw const FormatException('Sponge schematic has no Palette');
  }
  final palette = List<BlockStateRef>.filled(paletteTag.length, airBlockState);
  for (final entry in paletteTag.value.entries) {
    final index = (entry.value as NbtInt).value;
    if (index < 0 || index >= palette.length) {
      throw FormatException('palette index $index is out of range');
    }
    palette[index] = BlockStateRef.parse(entry.key);
  }

  // Version 3 names the array `Data`; versions 1 and 2 call it `BlockData`.
  final dataTag = version >= 3 ? holder['Data'] : holder['BlockData'];
  if (dataTag is! NbtByteArray) {
    throw const FormatException('Sponge schematic has no block data');
  }

  final volume = width * height * length;
  final cells = Int32List(volume);
  final reader = _VarIntReader(dataTag.value);
  for (var i = 0; i < volume; i++) {
    final index = reader.read();
    if (index >= palette.length) {
      throw FormatException('block $index is outside the palette');
    }
    cells[i] = index;
  }

  final offset = root['Offset'];
  final offsets = offset is NbtIntArray ? offset.value : Int32List(3);
  return Structure(
    sizeX: width,
    sizeY: height,
    sizeZ: length,
    palette: List.unmodifiable(palette),
    cells: cells,
    originX: offsets.isNotEmpty ? offsets[0] : 0,
    originY: offsets.length > 1 ? offsets[1] : 0,
    originZ: offsets.length > 2 ? offsets[2] : 0,
  );
}

/// Packs one varint per cell into a buffer of exactly the right size.
///
/// Two passes rather than appending byte by byte: the block data is one entry
/// per cell of the region, which for a 5x5 build is a hundred and fifty million
/// of them, and `BytesBuilder.addByte` measured at about a hundred nanoseconds
/// each — fifteen seconds of the export. Counting first is a cheap integer pass
/// and lets the second pass write into a plain array.
Uint8List _packVarInts(Int32List cells) {
  var size = 0;
  for (final index in cells) {
    size += _varIntLength(index);
  }
  final out = Uint8List(size);
  var at = 0;
  for (final index in cells) {
    var remaining = index;
    while (remaining >= 0x80) {
      out[at++] = (remaining & 0x7F) | 0x80;
      remaining >>>= 7;
    }
    out[at++] = remaining;
  }
  return out;
}

/// How many bytes [_packVarInts] will use for [value].
int _varIntLength(int value) {
  var length = 1;
  var remaining = value >>> 7;
  while (remaining != 0) {
    length++;
    remaining >>>= 7;
  }
  return length;
}

class _VarIntReader {
  _VarIntReader(this.bytes);

  final Uint8List bytes;
  int at = 0;

  int read() {
    var value = 0;
    var shift = 0;
    while (true) {
      if (at >= bytes.length) {
        throw const FormatException('the block data ends mid-varint');
      }
      final byte = bytes[at++];
      value |= (byte & 0x7F) << shift;
      if (byte & 0x80 == 0) return value;
      shift += 7;
      if (shift > 28) {
        throw const FormatException('a varint longer than five bytes');
      }
    }
  }
}

int _readShort(NbtTag? tag) {
  if (tag is! NbtShort) {
    throw const FormatException('a Sponge schematic size must be a short');
  }
  return tag.value;
}
