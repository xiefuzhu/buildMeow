import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'rgb.dart';

/// A plain RGBA8 image: `width * height * 4` bytes, row-major, top row first.
///
/// Deliberately not the `image` package's type. Keeping the pipeline on a raw
/// byte buffer means it can be handed to an isolate for free, and that
/// `mapart_core` stays a pure Dart package with no image codec dependency.
///
/// Row `0` is the **north** edge of the map, which is what the shade rule
/// compares against.
@immutable
class RgbaImage {
  RgbaImage(this.width, this.height)
    : assert(width > 0 && height > 0),
      bytes = Uint8List(width * height * 4);

  RgbaImage.fromBytes(this.width, this.height, this.bytes)
    : assert(width > 0 && height > 0),
      assert(bytes.length == width * height * 4, 'byte length must match size');

  final int width;
  final int height;

  /// RGBA, 4 bytes per pixel.
  final Uint8List bytes;

  int get pixelCount => width * height;

  int offsetOf(int x, int y) => (y * width + x) * 4;

  void setPixel(int x, int y, int r, int g, int b, [int a = 255]) {
    final o = offsetOf(x, y);
    bytes[o] = r;
    bytes[o + 1] = g;
    bytes[o + 2] = b;
    bytes[o + 3] = a;
  }

  void setRgb(int x, int y, Rgb color, [int a = 255]) =>
      setPixel(x, y, color.r, color.g, color.b, a);

  /// The colour at `(x, y)`, ignoring alpha.
  Rgb pixelAt(int x, int y) {
    final o = offsetOf(x, y);
    return Rgb(bytes[o], bytes[o + 1], bytes[o + 2]);
  }

  int alphaAt(int x, int y) => bytes[offsetOf(x, y) + 3];

  bool get isOpaque {
    for (var i = 3; i < bytes.length; i += 4) {
      if (bytes[i] != 255) return false;
    }
    return true;
  }

  /// Flattens alpha over [background], returning an opaque copy.
  ///
  /// Mapart has no transparency — every pixel becomes a block — so this runs
  /// before colour matching. Source-over compositing on non-premultiplied
  /// sRGB, which is what image editors do and close enough here.
  RgbaImage compositeOnto(Rgb background) {
    final out = RgbaImage(width, height);
    for (var i = 0; i < bytes.length; i += 4) {
      final a = bytes[i + 3];
      if (a == 255) {
        out.bytes[i] = bytes[i];
        out.bytes[i + 1] = bytes[i + 1];
        out.bytes[i + 2] = bytes[i + 2];
      } else if (a == 0) {
        out.bytes[i] = background.r;
        out.bytes[i + 1] = background.g;
        out.bytes[i + 2] = background.b;
      } else {
        final t = a / 255.0;
        out.bytes[i] = (bytes[i] * t + background.r * (1 - t)).round();
        out.bytes[i + 1] = (bytes[i + 1] * t + background.g * (1 - t)).round();
        out.bytes[i + 2] = (bytes[i + 2] * t + background.b * (1 - t)).round();
      }
      out.bytes[i + 3] = 255;
    }
    return out;
  }

  /// A copy with the north-west corner at `(x, y)`, used by the `cover` crop.
  RgbaImage cropped(int x, int y, int cropWidth, int cropHeight) {
    assert(x >= 0 && y >= 0);
    assert(x + cropWidth <= width && y + cropHeight <= height);
    final out = RgbaImage(cropWidth, cropHeight);
    for (var row = 0; row < cropHeight; row++) {
      final srcStart = offsetOf(x, y + row);
      final dstStart = out.offsetOf(0, row);
      out.bytes.setRange(dstStart, dstStart + cropWidth * 4, bytes, srcStart);
    }
    return out;
  }

  @override
  String toString() => 'RgbaImage(${width}x$height)';
}
