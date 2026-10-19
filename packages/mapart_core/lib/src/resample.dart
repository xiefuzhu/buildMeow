import 'dart:math' as math;

import 'lanczos.dart';
import 'rgb.dart';
import 'rgba_image.dart';

/// How a source image is mapped onto the rectangular map pixel grid.
enum CropMode {
  /// Scale to fill the grid, then centre-crop the overflow. Keeps the whole
  /// picture edge to edge but cuts off whichever axis is relatively longer.
  cover,

  /// Scale to fit inside the grid, then pad the rest with the background
  /// colour. Nothing is lost, but there may be blank bands.
  contain,
}

/// Resamples [source] onto a `targetWidth x targetHeight` grid.
///
/// Always goes through Lanczos, including for [CropMode.contain]'s padding
/// step, so the result is smooth regardless of whether the image is being
/// enlarged or shrunk.
RgbaImage fitToGrid(
  RgbaImage source,
  int targetWidth,
  int targetHeight, {
  required CropMode mode,
  required Rgb background,
}) {
  assert(targetWidth > 0 && targetHeight > 0);

  final scaleX = targetWidth / source.width;
  final scaleY = targetHeight / source.height;

  switch (mode) {
    case CropMode.cover:
      final scale = math.max(scaleX, scaleY);
      final scaledWidth = math.max(targetWidth, (source.width * scale).ceil());
      final scaledHeight = math.max(
        targetHeight,
        (source.height * scale).ceil(),
      );
      final resampled = resampleLanczos(source, scaledWidth, scaledHeight);
      return resampled.cropped(
        (scaledWidth - targetWidth) ~/ 2,
        (scaledHeight - targetHeight) ~/ 2,
        targetWidth,
        targetHeight,
      );

    case CropMode.contain:
      final scale = math.min(scaleX, scaleY);
      final scaledWidth = (source.width * scale).round().clamp(1, targetWidth);
      final scaledHeight = (source.height * scale).round().clamp(
        1,
        targetHeight,
      );
      final resampled = resampleLanczos(source, scaledWidth, scaledHeight);
      return _padCentred(resampled, targetWidth, targetHeight, background);
  }
}

/// Places [image] in the middle of a [width] x [height] canvas filled with
/// [background].
RgbaImage _padCentred(RgbaImage image, int width, int height, Rgb background) {
  if (image.width == width && image.height == height) return image;

  final out = RgbaImage(width, height);
  for (var i = 0; i < out.bytes.length; i += 4) {
    out.bytes[i] = background.r;
    out.bytes[i + 1] = background.g;
    out.bytes[i + 2] = background.b;
    out.bytes[i + 3] = 255;
  }

  final offsetX = (width - image.width) ~/ 2;
  final offsetY = (height - image.height) ~/ 2;
  for (var y = 0; y < image.height; y++) {
    final srcStart = image.offsetOf(0, y);
    final dstStart = out.offsetOf(offsetX, offsetY + y);
    out.bytes.setRange(
      dstStart,
      dstStart + image.width * 4,
      image.bytes,
      srcStart,
    );
  }
  return out;
}
