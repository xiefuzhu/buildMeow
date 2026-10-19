import 'dart:typed_data';

import 'package:meta/meta.dart';

/// The twelve NBT tag types, plus the end marker, as the binary format numbers
/// them.
abstract final class NbtTagId {
  static const int end = 0x00;
  static const int byte = 0x01;
  static const int short = 0x02;
  static const int int_ = 0x03;
  static const int long = 0x04;
  static const int float = 0x05;
  static const int double_ = 0x06;
  static const int byteArray = 0x07;
  static const int string = 0x08;
  static const int list = 0x09;
  static const int compound = 0x0A;
  static const int intArray = 0x0B;
  static const int longArray = 0x0C;
}

/// A named binary tag.
///
/// Modelled as an explicit class per type rather than as Dart primitives,
/// because NBT is strongly typed and `1` is a different file depending on
/// whether it is a byte, a short, an int or a long. Only the types the two
/// schematic formats need are implemented, which is all of them.
@immutable
sealed class NbtTag {
  const NbtTag();

  /// The id this tag is written with.
  int get id;
}

@immutable
class NbtByte extends NbtTag {
  const NbtByte(this.value);
  final int value;
  @override
  int get id => NbtTagId.byte;
  @override
  bool operator ==(Object other) => other is NbtByte && other.value == value;
  @override
  int get hashCode => Object.hash('byte', value);
  @override
  String toString() => 'NbtByte($value)';
}

@immutable
class NbtShort extends NbtTag {
  const NbtShort(this.value);
  final int value;
  @override
  int get id => NbtTagId.short;
  @override
  bool operator ==(Object other) => other is NbtShort && other.value == value;
  @override
  int get hashCode => Object.hash('short', value);
  @override
  String toString() => 'NbtShort($value)';
}

@immutable
class NbtInt extends NbtTag {
  const NbtInt(this.value);
  final int value;
  @override
  int get id => NbtTagId.int_;
  @override
  bool operator ==(Object other) => other is NbtInt && other.value == value;
  @override
  int get hashCode => Object.hash('int', value);
  @override
  String toString() => 'NbtInt($value)';
}

/// A 64-bit signed integer. Dart's own `int` is exactly that on the native
/// platforms this app runs on, so the value is stored directly.
@immutable
class NbtLong extends NbtTag {
  const NbtLong(this.value);
  final int value;
  @override
  int get id => NbtTagId.long;
  @override
  bool operator ==(Object other) => other is NbtLong && other.value == value;
  @override
  int get hashCode => Object.hash('long', value);
  @override
  String toString() => 'NbtLong($value)';
}

@immutable
class NbtFloat extends NbtTag {
  const NbtFloat(this.value);
  final double value;
  @override
  int get id => NbtTagId.float;
  @override
  bool operator ==(Object other) => other is NbtFloat && other.value == value;
  @override
  int get hashCode => Object.hash('float', value);
  @override
  String toString() => 'NbtFloat($value)';
}

@immutable
class NbtDouble extends NbtTag {
  const NbtDouble(this.value);
  final double value;
  @override
  int get id => NbtTagId.double_;
  @override
  bool operator ==(Object other) => other is NbtDouble && other.value == value;
  @override
  int get hashCode => Object.hash('double', value);
  @override
  String toString() => 'NbtDouble($value)';
}

@immutable
class NbtString extends NbtTag {
  const NbtString(this.value);
  final String value;
  @override
  int get id => NbtTagId.string;
  @override
  bool operator ==(Object other) => other is NbtString && other.value == value;
  @override
  int get hashCode => Object.hash('string', value);
  @override
  String toString() => 'NbtString($value)';
}

@immutable
class NbtByteArray extends NbtTag {
  NbtByteArray(this.value);
  final Uint8List value;
  @override
  int get id => NbtTagId.byteArray;
  @override
  bool operator ==(Object other) =>
      other is NbtByteArray && _sameBytes(other.value, value);
  @override
  int get hashCode => Object.hash('bytes', value.length, Object.hashAll(value));
  @override
  String toString() => 'NbtByteArray(${value.length})';
}

@immutable
class NbtIntArray extends NbtTag {
  NbtIntArray(this.value);
  final Int32List value;
  @override
  int get id => NbtTagId.intArray;
  @override
  bool operator ==(Object other) =>
      other is NbtIntArray && _sameInts(other.value, value);
  @override
  int get hashCode => Object.hash('ints', value.length, Object.hashAll(value));
  @override
  String toString() => 'NbtIntArray(${value.length})';
}

@immutable
class NbtLongArray extends NbtTag {
  NbtLongArray(this.value);
  final Int64List value;
  @override
  int get id => NbtTagId.longArray;
  @override
  bool operator ==(Object other) =>
      other is NbtLongArray && _sameLongs(other.value, value);
  @override
  int get hashCode => Object.hash('longs', value.length, Object.hashAll(value));
  @override
  String toString() => 'NbtLongArray(${value.length})';
}

/// A list whose entries all share one tag type, which is how NBT stores them.
///
/// An empty list has no element type to record, and NBT writes it as `end`.
@immutable
class NbtList extends NbtTag {
  const NbtList(this.value);
  final List<NbtTag> value;
  @override
  int get id => NbtTagId.list;
  @override
  bool operator ==(Object other) =>
      other is NbtList && _sameList(other.value, value);
  @override
  int get hashCode => Object.hash('list', Object.hashAll(value));
  @override
  String toString() => 'NbtList(${value.length})';
}

/// A named collection of tags.
@immutable
class NbtCompound extends NbtTag {
  NbtCompound([Map<String, NbtTag>? value])
    : value = Map.unmodifiable(value ?? const <String, NbtTag>{});

  final Map<String, NbtTag> value;

  @override
  int get id => NbtTagId.compound;

  bool has(String name) => value.containsKey(name);

  NbtTag? operator [](String name) => value[name];

  int get length => value.length;

  @override
  bool operator ==(Object other) =>
      other is NbtCompound && _sameCompound(other.value, value);

  @override
  int get hashCode => Object.hash(
    'compound',
    Object.hashAll([
      for (final entry in value.entries) Object.hash(entry.key, entry.value),
    ]),
  );

  @override
  String toString() => 'NbtCompound(${value.keys.join(', ')})';
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameInts(Int32List a, Int32List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameLongs(Int64List a, Int64List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameList(List<NbtTag> a, List<NbtTag> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameCompound(Map<String, NbtTag> a, Map<String, NbtTag> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
