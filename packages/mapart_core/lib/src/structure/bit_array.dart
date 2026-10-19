import 'dart:typed_data';

/// Litematica's own bit packing, which is *not* the one Minecraft uses.
///
/// Entries are packed back to back and are allowed to **straddle a long
/// boundary**: entry `i` starts at bit `i * bitsPerEntry` of the array and takes
/// the next `bitsPerEntry` bits, wherever they land. Vanilla's chunk format
/// instead pads each long so no entry crosses, and using that packing here
/// produces a file Litematica reads as noise.
///
/// Verified against `LitematicaBitArray.java` in Litematica's
/// `pre-rewrite/fabric/1.21.1-masa` branch: the shifts, the `roundUp` that
/// decides the array length, and the `bitsPerEntry` minimum of 2 are all its.
class LitematicaBitArray {
  LitematicaBitArray(this.bitsPerEntry, this.size, [Int64List? backing])
    : assert(bitsPerEntry >= 1 && bitsPerEntry <= 32),
      mask = (1 << bitsPerEntry) - 1,
      backing = backing ?? Int64List(longCountFor(size, bitsPerEntry));

  final int bitsPerEntry;

  /// How many entries the array holds, which is not its length in longs.
  final int size;

  final Int64List backing;

  /// `(1 << bitsPerEntry) - 1`, precomputed: the packing loop runs once per cell
  /// of the region, which for a 5x5 build is a hundred million times, and
  /// recomputing this on every entry was measurable.
  final int mask;

  /// The number of bits a palette of [paletteSize] entries needs.
  ///
  /// Litematica's `createFrom`: `max(2, 32 - numberOfLeadingZeros(size - 1))`.
  /// A one-entry palette still takes two bits, which is why the minimum is not
  /// simply the number of bits the largest index needs.
  static int bitsFor(int paletteSize) {
    if (paletteSize <= 1) return 2;
    var bits = 0;
    var value = paletteSize - 1;
    while (value > 0) {
      bits++;
      value >>= 1;
    }
    return bits < 2 ? 2 : bits;
  }

  /// How many longs hold [size] entries of [bits] bits each.
  ///
  /// At least one, even for an empty array: `roundUp(0, 64)` is 64 in
  /// Litematica's helper, and a zero-length `BlockStates` tag would be rejected
  /// by the reader.
  static int longCountFor(int size, int bits) {
    final bits_ = size * bits;
    if (bits_ == 0) return 1;
    return (bits_ + 63) ~/ 64;
  }

  int getAt(int index) {
    final startOffset = index * bitsPerEntry;
    final startArrayIndex = startOffset >> 6;
    final startBitOffset = startOffset & 0x3F;

    if (startBitOffset + bitsPerEntry <= 64) {
      return (backing[startArrayIndex] >>> startBitOffset) & mask;
    }
    final endOffset = 64 - startBitOffset;
    return ((backing[startArrayIndex] >>> startBitOffset) |
            (backing[startArrayIndex + 1] << endOffset)) &
        mask;
  }

  void setAt(int index, int value) {
    final startOffset = index * bitsPerEntry;
    final startArrayIndex = startOffset >> 6;
    final startBitOffset = startOffset & 0x3F;
    final masked = value & mask;

    if (startBitOffset + bitsPerEntry <= 64) {
      backing[startArrayIndex] =
          (backing[startArrayIndex] & ~(mask << startBitOffset)) |
          (masked << startBitOffset);
      return;
    }

    // The entry straddles two longs: its low bits end up at the top of the
    // first and the rest at the bottom of the second.
    backing[startArrayIndex] =
        (backing[startArrayIndex] & ~(mask << startBitOffset)) |
        (masked << startBitOffset);
    final endOffset = 64 - startBitOffset;
    final shift = bitsPerEntry - endOffset;
    backing[startArrayIndex + 1] =
        (backing[startArrayIndex + 1] >>> shift << shift) |
        (masked >> endOffset);
  }
}
