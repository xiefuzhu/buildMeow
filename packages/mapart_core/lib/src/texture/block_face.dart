import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../rgb.dart';

/// A face of a block, and the brightness the game shades it with.
///
/// The multipliers are vanilla's: a block model's face is lit by a fixed factor
/// per direction, which is why the top of a cube looks brighter than its sides
/// and the underside is darkest. Values verified against the game's own
/// constants (up 1.0, north/south 0.8, east/west 0.6, down 0.5).
///
/// They matter because a texture is authored flat. Reading the top face of a
/// block and then building a wall means every pixel is drawn on a *side*, where
/// the game will darken it — so a palette built from top faces and used on a
/// wall comes out consistently too bright unless the factor is applied.
enum BlockFace {
  up('up', 1.0),
  down('down', 0.5),
  north('north', 0.8),
  south('south', 0.8),
  west('west', 0.6),
  east('east', 0.6);

  const BlockFace(this.key, this.brightness);

  /// The key the block model JSON uses for this face.
  final String key;

  /// Vanilla's brightness multiplier for this face.
  final double brightness;

  /// The four faces a wall pixel can show.
  static const List<BlockFace> horizontal = <BlockFace>[
    north,
    south,
    west,
    east,
  ];

  static BlockFace? byKey(String key) {
    for (final face in BlockFace.values) {
      if (face.key == key) return face;
    }
    return null;
  }
}

/// A colour as three linear-light components, each `0..1`.
///
/// Separate from [Rgb], which is 8-bit sRGB and cannot represent the value the
/// averaging actually produces.
@immutable
class LinearRgb {
  const LinearRgb(this.r, this.g, this.b);

  final double r;
  final double g;
  final double b;

  List<double> toJson() => <double>[
    double.parse(r.toStringAsFixed(6)),
    double.parse(g.toStringAsFixed(6)),
    double.parse(b.toStringAsFixed(6)),
  ];

  @override
  String toString() =>
      'LinearRgb(${r.toStringAsFixed(4)}, '
      '${g.toStringAsFixed(4)}, ${b.toStringAsFixed(4)})';
}

/// The sRGB transfer curve, as a pair of lookups.
///
/// The curve is not a multiply, so averaging in sRGB and averaging in linear
/// light disagree: black and white average to 128 the naive way and to 188 the
/// correct way. That difference is visible on a map, which is the whole reason
/// the average is taken in linear light.
double srgbToLinear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double linearToSrgb(double c) {
  final v = c.clamp(0.0, 1.0);
  return v <= 0.0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4) - 0.055;
}

/// What a texture averages to.
@immutable
class AverageColor {
  const AverageColor({
    required this.srgb,
    required this.linear,
    required this.noisiness,
    required this.opaquePixels,
  });

  /// The average, back in 8-bit sRGB. This is what goes on the map.
  final Rgb srgb;

  /// The same average in linear light, before the transfer curve.
  final LinearRgb linear;

  /// Population standard deviation of Rec.709 luminance over the counted
  /// pixels, in 0-255 sRGB units.
  ///
  /// This is the "noisiness": two textures can average to the same colour while
  /// one is flat and the other is speckled, and a speckled one tiled across a
  /// wall reads as static rather than as the colour it averages to. Worked
  /// example from the spec: 120/125/130/125 averages 125 with a deviation of
  /// 3.5, while 60/60/200/200 averages 130 with a deviation of 70.
  final double noisiness;

  /// How many pixels went into the average, i.e. those not fully transparent.
  final int opaquePixels;

  @override
  String toString() =>
      'AverageColor($srgb, noisiness '
      '${noisiness.toStringAsFixed(2)}, $opaquePixels px)';
}

/// Averages an RGBA texture in linear light.
///
/// [pixels] is `width * height * 4` bytes, RGBA, as `image` decodes PNG.
/// Fully transparent pixels are skipped; if every pixel is transparent the
/// result is `null`, because there is no colour to average.
AverageColor? averageTexture(Uint8List pixels, int width, int height) {
  final count = width * height;
  if (pixels.length < count * 4) {
    throw ArgumentError('expected ${count * 4} bytes, got ${pixels.length}');
  }

  var r = 0.0, g = 0.0, b = 0.0;
  var luminanceSum = 0.0, luminanceSquaredSum = 0.0;
  var counted = 0;

  for (var p = 0; p < count; p++) {
    final o = p * 4;
    if (pixels[o + 3] == 0) continue;
    final lr = srgbToLinear(pixels[o] / 255);
    final lg = srgbToLinear(pixels[o + 1] / 255);
    final lb = srgbToLinear(pixels[o + 2] / 255);
    r += lr;
    g += lg;
    b += lb;

    // Rec.709 luminance in sRGB units, so the number is in 0-255 and matches
    // the spec's worked example.
    final luma =
        0.2126 * pixels[o] + 0.7152 * pixels[o + 1] + 0.0722 * pixels[o + 2];
    luminanceSum += luma;
    luminanceSquaredSum += luma * luma;
    counted++;
  }

  if (counted == 0) return null;

  final meanR = r / counted;
  final meanG = g / counted;
  final meanB = b / counted;

  final meanLuma = luminanceSum / counted;
  final variance = math.max(
    0.0,
    luminanceSquaredSum / counted - meanLuma * meanLuma,
  );

  return AverageColor(
    srgb: Rgb(
      (linearToSrgb(meanR) * 255).round().clamp(0, 255),
      (linearToSrgb(meanG) * 255).round().clamp(0, 255),
      (linearToSrgb(meanB) * 255).round().clamp(0, 255),
    ),
    linear: LinearRgb(meanR, meanG, meanB),
    noisiness: math.sqrt(variance),
    opaquePixels: counted,
  );
}

/// Whether a texture uses partial transparency anywhere.
///
/// A texture that is either fully opaque or fully clear is a cut-out and can
/// still be averaged; anything in between is glass-like and is excluded, since
/// a translucent block does not show its own colour on a map.
bool hasPartialAlpha(Uint8List pixels) {
  for (var i = 3; i < pixels.length; i += 4) {
    final a = pixels[i];
    if (a != 0 && a != 255) return true;
  }
  return false;
}
