import 'dart:convert';
import 'dart:typed_data';

import 'nbt_tag.dart';
import 'nbt_writer.dart';

/// A tag tree read back from NBT.
typedef NbtFile = ({String name, NbtCompound root});

/// Reads a tag tree, gzipped or not.
///
/// The two formats disagree about compression in practice — Litematica always
/// gzips, WorldEdit writes gzipped `.schem` but accepts either — so the magic
/// bytes decide rather than the caller. Reading is here mainly so the round-trip
/// test can check the writer, which is the acceptance criterion for the
/// schematics: a file this project writes has to be readable by this project
/// before it is worth loading into the game.
NbtFile readNbt(Uint8List bytes) {
  final raw = _isGzip(bytes) ? _gunzip(bytes) : bytes;
  final reader = _Reader(raw);
  final id = reader.readByte();
  if (id != NbtTagId.compound) {
    throw FormatException('an NBT file starts with a compound, got id $id');
  }
  final name = reader.readString();
  return (name: name, root: reader.readCompoundPayload());
}

bool _isGzip(Uint8List bytes) =>
    bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B;

Uint8List _gunzip(Uint8List bytes) {
  try {
    return gunzipBytes(bytes);
  } on Object catch (error) {
    throw FormatException('not a gzip stream: $error');
  }
}

class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int at = 0;

  int readByte() {
    if (at >= bytes.length) {
      throw const FormatException('the file ends in the middle of a tag');
    }
    return bytes[at++];
  }

  int readShort() {
    final high = readByte();
    final low = readByte();
    return (high << 8) | low;
  }

  /// Reads a signed 32-bit int, which is what a `NbtInt` holds.
  int readInt() {
    final unsigned = readIntUnsigned();
    return unsigned >= 0x80000000 ? unsigned - 0x100000000 : unsigned;
  }

  /// Reads four bytes as an unsigned 32-bit int, for lengths and float bits.
  int readIntUnsigned() {
    var value = 0;
    for (var i = 0; i < 4; i++) {
      value = (value << 8) | readByte();
    }
    return value;
  }

  /// Reads a signed 64-bit long. Dart's `int` is 64-bit two's complement on
  /// every platform this runs on, so accumulating eight bytes wraps to exactly
  /// the value that was written.
  int readLong() {
    var value = 0;
    for (var i = 0; i < 8; i++) {
      value = (value << 8) | readByte();
    }
    return value;
  }

  /// Reads a length-prefixed string as plain UTF-8. See `nbt_writer.dart` for
  /// why modified UTF-8 is not needed here.
  String readString() {
    final length = readShort();
    _need(length);
    final value = utf8.decode(bytes.sublist(at, at + length));
    at += length;
    return value;
  }

  Uint8List readBytes(int length) {
    _need(length);
    final value = Uint8List.sublistView(bytes, at, at + length);
    at += length;
    return Uint8List.fromList(value);
  }

  void _need(int length) {
    if (at + length > bytes.length) {
      throw const FormatException('the file ends in the middle of a tag');
    }
  }

  NbtCompound readCompoundPayload() {
    final out = <String, NbtTag>{};
    while (true) {
      final id = readByte();
      if (id == NbtTagId.end) break;
      final name = readString();
      out[name] = readPayload(id);
    }
    return NbtCompound(out);
  }

  NbtTag readPayload(int id) {
    switch (id) {
      case NbtTagId.byte:
        // Signed, so 0xFF is -1 rather than 255.
        final value = readByte();
        return NbtByte(value >= 0x80 ? value - 0x100 : value);
      case NbtTagId.short:
        final value = readShort();
        return NbtShort(value >= 0x8000 ? value - 0x10000 : value);
      case NbtTagId.int_:
        return NbtInt(readInt());
      case NbtTagId.long:
        return NbtLong(readLong());
      case NbtTagId.float:
        return NbtFloat(_intToFloat(readIntUnsigned()));
      case NbtTagId.double_:
        return NbtDouble(_longToDouble(readLong()));
      case NbtTagId.string:
        return NbtString(readString());
      case NbtTagId.byteArray:
        return NbtByteArray(readBytes(_readLength()));
      case NbtTagId.intArray:
        final count = _readLength();
        return NbtIntArray(_readIntArray(count));
      case NbtTagId.longArray:
        final count = _readLength();
        return NbtLongArray(_readLongArray(count));
      case NbtTagId.list:
        final elementId = readByte();
        final count = _readLength();
        if (elementId == NbtTagId.end) {
          // An empty list carries no element type, so its length must be zero.
          if (count != 0) {
            throw const FormatException('a list of ends with entries in it');
          }
          return const NbtList([]);
        }
        return NbtList([
          for (var i = 0; i < count; i++) readPayload(elementId),
        ]);
      case NbtTagId.compound:
        return readCompoundPayload();
    }
    throw FormatException('unknown tag id $id at byte ${at - 1}');
  }

  /// Reads a length or count, rejecting a negative one.
  int _readLength() {
    final length = readIntUnsigned();
    if (length > 0x7FFFFFFF) {
      throw const FormatException('a negative array length');
    }
    return length;
  }

  /// Reads a whole array in one view rather than four bytes at a time: a 5x5
  /// block-state array is millions of longs.
  Int64List _readLongArray(int count) {
    _need(count * 8);
    final out = Int64List(count);
    final view = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes + at,
      count * 8,
    );
    for (var i = 0; i < count; i++) {
      out[i] = view.getInt64(i * 8, Endian.big);
    }
    at += count * 8;
    return out;
  }

  Int32List _readIntArray(int count) {
    _need(count * 4);
    final out = Int32List(count);
    final view = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes + at,
      count * 4,
    );
    for (var i = 0; i < count; i++) {
      out[i] = view.getInt32(i * 4, Endian.big);
    }
    at += count * 4;
    return out;
  }

  double _intToFloat(int bits) =>
      (Int32List(1)..[0] = bits).buffer.asByteData().getFloat32(0);

  double _longToDouble(int bits) =>
      (Int64List(1)..[0] = bits).buffer.asByteData().getFloat64(0);
}
