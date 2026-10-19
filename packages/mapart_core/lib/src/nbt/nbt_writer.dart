import 'dart:convert';
import 'dart:io' show GZipCodec;
import 'dart:typed_data';

import 'nbt_tag.dart';

/// Serialises a tag tree to NBT.
///
/// Big-endian, `[tag id][name length u16][name utf8][payload]`, and a compound
/// terminated by a zero tag id 鈥?the layout every Minecraft file uses.
///
/// Gzip wrapping is here rather than at the call sites because both schematic
/// formats require it, and because doing it twice on a buffer that is already
/// compressed would still "work" while quietly doubling the file size.
Uint8List writeNbt(NbtCompound root, {String name = '', bool gzip = true}) {
  final out = BytesBuilder(copy: false);
  // The root compound's own end byte is written by its payload, so nothing is
  // appended here: a file with a trailing zero would still read back, which is
  // exactly the kind of bug that only shows up in another program.
  _writeTag(out, name, root);
  final bytes = out.takeBytes();
  return gzip ? gzipBytes(bytes) : bytes;
}

/// Wraps [bytes] in gzip.
///
/// `dart:io`'s codec, which is the platform's zlib, rather than the pure-Dart
/// one in `archive`: measured on a 5x5 export, the pure-Dart deflate took 11.5
/// seconds for an 851 KB file where zlib does the same work in well under a
/// second. Nothing here runs on the web, so the platform codec is available
/// everywhere this app does.
Uint8List gzipBytes(Uint8List bytes) =>
    Uint8List.fromList(GZipCodec().encode(bytes));

/// Unwraps gzip.
Uint8List gunzipBytes(Uint8List bytes) =>
    Uint8List.fromList(GZipCodec().decode(bytes));

void _writeTag(BytesBuilder out, String name, NbtTag tag) {
  out.addByte(tag.id);
  _writeString(out, name);
  _writePayload(out, tag);
}

void _writePayload(BytesBuilder out, NbtTag tag) {
  switch (tag) {
    case NbtByte(:final value):
      out.addByte(value & 0xFF);
    case NbtShort(:final value):
      _writeShort(out, value);
    case NbtInt(:final value):
      _writeInt(out, value);
    case NbtLong(:final value):
      _writeLong(out, value);
    case NbtFloat(:final value):
      _writeInt(out, _floatBits(value));
    case NbtDouble(:final value):
      _writeLong(out, _doubleBits(value));
    case NbtString(:final value):
      _writeString(out, value);
    case NbtByteArray(:final value):
      _writeInt(out, value.length);
      out.add(value);
    case NbtIntArray(:final value):
      _writeInt(out, value.length);
      out.add(_intArrayBytes(value));
    case NbtLongArray(:final value):
      _writeInt(out, value.length);
      out.add(_longArrayBytes(value));
    case NbtList(:final value):
      // The element type is recorded once, so every entry must share it.
      final elementId = value.isEmpty ? NbtTagId.end : value.first.id;
      out.addByte(elementId);
      _writeInt(out, value.length);
      for (final entry in value) {
        if (entry.id != elementId) {
          throw ArgumentError(
            'an NBT list holds one tag type; got $elementId and ${entry.id}',
          );
        }
        _writePayload(out, entry);
      }
    case NbtCompound(:final value):
      for (final entry in value.entries) {
        _writeTag(out, entry.key, entry.value);
      }
      out.addByte(NbtTagId.end);
  }
}

/// Writes a length-prefixed string.
///
/// Java writes NBT strings as *modified* UTF-8, which differs from plain UTF-8
/// only for the null character and for characters outside the basic
/// multilingual plane. Every string this app writes is a block id, a file name
/// or a Chinese label, all of which encode identically, so plain UTF-8 is used
/// and the difference is noted here rather than worked around.
void _writeString(BytesBuilder out, String value) {
  final bytes = utf8.encode(value);
  if (bytes.length > 0xFFFF) {
    throw ArgumentError('an NBT string cannot exceed 65535 bytes');
  }
  _writeShort(out, bytes.length);
  out.add(bytes);
}

void _writeShort(BytesBuilder out, int value) {
  out.addByte((value >> 8) & 0xFF);
  out.addByte(value & 0xFF);
}

void _writeInt(BytesBuilder out, int value) {
  out.addByte((value >> 24) & 0xFF);
  out.addByte((value >> 16) & 0xFF);
  out.addByte((value >> 8) & 0xFF);
  out.addByte(value & 0xFF);
}

void _writeLong(BytesBuilder out, int value) {
  for (var shift = 56; shift >= 0; shift -= 8) {
    out.addByte((value >> shift) & 0xFF);
  }
}

/// Packs an array into one buffer and hands it over whole.
///
/// A block-state array is a long per six blocks of the region, so a 5x5 build
/// is millions of longs; writing eight bytes at a time through `BytesBuilder`
/// was the slowest part of the export by a wide margin.
Uint8List _longArrayBytes(Int64List values) {
  final bytes = Uint8List(values.length * 8);
  final view = ByteData.view(bytes.buffer);
  for (var i = 0; i < values.length; i++) {
    view.setInt64(i * 8, values[i], Endian.big);
  }
  return bytes;
}

Uint8List _intArrayBytes(Int32List values) {
  final bytes = Uint8List(values.length * 4);
  final view = ByteData.view(bytes.buffer);
  for (var i = 0; i < values.length; i++) {
    view.setInt32(i * 4, values[i], Endian.big);
  }
  return bytes;
}

int _floatBits(double value) =>
    (Float32List(1)..[0] = value).buffer.asByteData().getUint32(0);

int _doubleBits(double value) =>
    (Float64List(1)..[0] = value).buffer.asByteData().getUint64(0);
