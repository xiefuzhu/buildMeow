import 'dart:typed_data';

import 'package:mapart_core/mapart_core.dart';
import 'package:test/test.dart';

/// The NBT layer the two schematic writers sit on.
///
/// Written against the specification rather than against itself: the exact-bytes
/// test is hand-computed from the tag layout, so a writer and a reader that
/// agree with each other but not with the game cannot pass.
void main() {
  group('exact bytes', () {
    test('a compound with one int is the byte sequence from the spec', () {
      // NBT binary: [tag id][name length u16][name utf8][payload], big-endian,
      // a compound ended by a 0x00 tag id, and a root compound whose name is
      // usually empty.
      final bytes = writeNbt(
        NbtCompound({'a': const NbtInt(1)}),
        gzip: false,
      );
      expect(bytes, [
        0x0A, // compound
        0x00, 0x00, // root name: empty
        0x03, // int
        0x00, 0x01, 0x61, // "a"
        0x00, 0x00, 0x00, 0x01, // 1, big-endian
        0x00, // end of compound
      ]);
    });

    test('every tag type has the id the specification gives it', () {
      final bytes = writeNbt(
        NbtCompound({
          'b': const NbtByte(1),
          's': const NbtShort(1),
          'i': const NbtInt(1),
          'l': const NbtLong(1),
          'f': const NbtFloat(1),
          'd': const NbtDouble(1),
          'ba': NbtByteArray(Uint8List.fromList([1])),
          'str': const NbtString('x'),
          'list': NbtList([const NbtInt(1)]),
          'ia': NbtIntArray(Int32List.fromList([1])),
          'la': NbtLongArray(Int64List.fromList([1])),
          'c': NbtCompound({'z': const NbtInt(1)}),
        }),
        gzip: false,
      );
      // Walk the top level and collect the tag ids, which is the part of the
      // layout that is easiest to get subtly wrong.
      final ids = <int>[];
      var at = 3; // compound id + empty root name
      while (at < bytes.length) {
        final id = bytes[at];
        if (id == 0) break;
        ids.add(id);
        final nameLength = (bytes[at + 1] << 8) | bytes[at + 2];
        var cursor = at + 3 + nameLength;
        cursor = _skipPayload(bytes, id, cursor);
        at = cursor;
      }
      expect(ids, [
        0x01, // byte
        0x02, // short
        0x03, // int
        0x04, // long
        0x05, // float
        0x06, // double
        0x07, // byte array
        0x08, // string
        0x09, // list
        0x0B, // int array
        0x0C, // long array
        0x0A, // compound
      ]);
    });
  });

  group('round trip', () {
    test('every tag type comes back unchanged', () {
      final original = NbtCompound({
        'byte': const NbtByte(-12),
        'short': const NbtShort(-3000),
        'int': const NbtInt(-70000),
        'long': const NbtLong(-9223372036854775808),
        'longPositive': const NbtLong(9223372036854775807),
        'float': const NbtFloat(0.5),
        'double': const NbtDouble(-1.25),
        'string': const NbtString('minecraft:white_concrete'),
        'chinese': const NbtString('白色混凝土 参照行'),
        'empty': const NbtString(''),
        'bytes': NbtByteArray(Uint8List.fromList([0, 1, 255])),
        'ints': NbtIntArray(Int32List.fromList([0, -1, 2147483647])),
        'longs': NbtLongArray(Int64List.fromList([0, -1, 1234567890123])),
        'list': NbtList([
          const NbtInt(1),
          const NbtInt(-2),
        ]),
        'compounds': NbtList([
          NbtCompound({'a': const NbtInt(1)}),
          NbtCompound({'a': const NbtString('two')}),
        ]),
        'emptyList': NbtList(const []),
        'nested': NbtCompound({
          'deeper': NbtCompound({'x': NbtLongArray(Int64List(0))}),
        }),
      });

      final read = readNbt(writeNbt(original, gzip: false)).root;
      expect(read, original);
      // And the other direction, so a reader that silently drops a tag cannot
      // pass by writing the same thing back.
      final again = readNbt(writeNbt(read, gzip: false)).root;
      expect(again, original);
    });

    test('a long array keeps all 64 bits of every entry', () {
      // The block-state arrays pack palette indices across long boundaries, so
      // a lost high bit would corrupt the schematic rather than fail loudly.
      final values = Int64List.fromList([
        -1, // all bits set
        -9223372036854775808, // sign bit only
        9223372036854775807,
        0x0123456789ABCDEF,
      ]);
      final read = readNbt(
        writeNbt(NbtCompound({'a': NbtLongArray(values)}), gzip: false),
      ).root;
      expect((read['a']! as NbtLongArray).value, values);
    });

    test('gzip is applied when asked for, and detected on the way back', () {
      final raw = writeNbt(NbtCompound({'a': const NbtInt(1)}), gzip: false);
      final compressed = writeNbt(
        NbtCompound({'a': const NbtInt(1)}),
        gzip: true,
      );
      expect(compressed.sublist(0, 2), [0x1F, 0x8B]);
      expect(compressed.length, lessThan(raw.length + 40));

      // Both forms read, and both give the same tag.
      final fromCompressed = readNbt(compressed);
      final fromRaw = readNbt(raw);
      expect(fromCompressed.root, fromRaw.root);
      expect(fromCompressed.root['a'], const NbtInt(1));
    });

    test('a named root keeps its name', () {
      final bytes = writeNbt(
        NbtCompound({'a': const NbtInt(1)}),
        name: 'Schematic',
        gzip: false,
      );
      final read = readNbt(bytes);
      expect(read.name, 'Schematic');
      expect(read.root['a'], const NbtInt(1));
    });
  });

  group('bad input', () {
    test('a truncated file fails loudly rather than returning a short tag', () {
      final bytes = writeNbt(
        NbtCompound({'a': NbtLongArray(Int64List.fromList([1, 2, 3]))}),
        gzip: false,
      );
      expect(
        () => readNbt(bytes.sublist(0, bytes.length - 4)),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => readNbt(Uint8List.fromList(const [1, 2, 3, 4])),
        throwsA(isA<FormatException>()),
      );
    });

    test('an unknown tag id is rejected', () {
      expect(
        () => readNbt(Uint8List.fromList(const [0x0A, 0, 0, 0x7F, 0, 0, 0])),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

/// Advances past a payload whose tag id is [id], for the tag-id walk above.
int _skipPayload(Uint8List bytes, int id, int at) {
  int readU16(int p) => (bytes[p] << 8) | bytes[p + 1];
  int readU32(int p) =>
      (bytes[p] << 24) | (bytes[p + 1] << 16) | (bytes[p + 2] << 8) | bytes[p + 3];

  switch (id) {
    case 0x01:
      return at + 1;
    case 0x02:
      return at + 2;
    case 0x03:
    case 0x05:
      return at + 4;
    case 0x04:
    case 0x06:
      return at + 8;
    case 0x07:
      return at + 4 + readU32(at);
    case 0x0B:
      return at + 4 + readU32(at) * 4;
    case 0x0C:
      return at + 4 + readU32(at) * 8;
    case 0x08:
      final length = readU16(at);
      return at + 2 + length;
    case 0x09:
      final elementId = bytes[at];
      var cursor = at + 5; // element id + count
      final count = readU32(at + 1);
      for (var i = 0; i < count; i++) {
        cursor = _skipPayload(bytes, elementId, cursor);
      }
      return cursor;
    case 0x0A:
      var cursor = at;
      while (bytes[cursor] != 0) {
        final childId = bytes[cursor];
        final nameLength = readU16(cursor + 1);
        cursor = _skipPayload(bytes, childId, cursor + 3 + nameLength);
      }
      return cursor + 1;
  }
  throw FormatException('unknown tag id $id');
}
