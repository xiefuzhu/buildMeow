import 'dart:math' as math;

import 'package:meta/meta.dart';

/// `sRGB channel -> linear light` lookup, built once. Converting a whole
/// 128x128 image is 16k calls, so this is worth caching.
final List<double> _linearLut = List<double>.generate(256, (i) {
  final c = i / 255.0;
  return c <= 0.04045
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}, growable: false);

const double _delta = 6.0 / 29.0;
const double _deltaCubed = _delta * _delta * _delta;

double _f(double t) => t > _deltaCubed
    ? math.pow(t, 1 / 3).toDouble()
    : t / (3 * _delta * _delta) + 4 / 29;

double _fInv(double t) =>
    t > _delta ? t * t * t : 3 * _delta * _delta * (t - 4 / 29);

/// A point in CIELAB (D65 white point).
///
/// Colour matching happens here rather than in sRGB because Euclidean distance
/// in sRGB does not track perceived difference — two greens that look nothing
/// alike can be as far apart as two near-identical greys.
@immutable
class Lab {
  const Lab(this.l, this.a, this.b);

  /// Converts an 8-bit sRGB colour to Lab via linear RGB and XYZ (D65).
  factory Lab.fromRgb(int r, int g, int b) {
    final lr = _linearLut[r];
    final lg = _linearLut[g];
    final lb = _linearLut[b];

    // Linear sRGB -> XYZ, D65.
    final x = 0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb;
    final y = 0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb;
    final z = 0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb;

    final fx = _f(x / 0.95047);
    final fy = _f(y / 1.0);
    final fz = _f(z / 1.08883);

    return Lab(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz));
  }

  final double l;
  final double a;
  final double b;

  /// Distance from the neutral axis, `sqrt(a^2 + b^2)`.
  double get chroma => math.sqrt(a * a + b * b);

  /// CIE76 colour difference.
  ///
  /// Cheap, and good enough for picking the nearest of a few hundred map
  /// colours — the palette is coarse enough that a fancier metric such as
  /// CIEDE2000 would rarely change the winner.
  double distanceTo(Lab other) {
    final dl = l - other.l;
    final da = a - other.a;
    final db = b - other.b;
    return math.sqrt(dl * dl + da * da + db * db);
  }

  /// CIEDE2000 colour difference.
  ///
  /// Noticeably more expensive than [distanceTo] and much better behaved for
  /// low-chroma colours, which is exactly where CIE76 tends to pick a neutral
  /// grey over a slightly tinted colour that would look more like the original.
  ///
  /// Implemented from the CIE specification; `kL = kC = kH = 1`.
  double ciede2000To(Lab other) {
    final c1 = math.sqrt(a * a + b * b);
    final c2 = math.sqrt(other.a * other.a + other.b * other.b);
    final cBar = (c1 + c2) / 2;

    final cBar7 = _pow7(cBar);
    final g = 0.5 * (1 - math.sqrt(cBar7 / (cBar7 + _twentyFive7)));

    final a1Prime = (1 + g) * a;
    final a2Prime = (1 + g) * other.a;
    final c1Prime = math.sqrt(a1Prime * a1Prime + b * b);
    final c2Prime = math.sqrt(a2Prime * a2Prime + other.b * other.b);

    final h1Prime = _hueDegrees(b, a1Prime);
    final h2Prime = _hueDegrees(other.b, a2Prime);

    final deltaL = other.l - l;
    final deltaC = c2Prime - c1Prime;

    double deltaSmallH;
    if (c1Prime * c2Prime == 0) {
      deltaSmallH = 0;
    } else {
      final diff = h2Prime - h1Prime;
      if (diff.abs() <= 180) {
        deltaSmallH = diff;
      } else if (diff > 180) {
        deltaSmallH = diff - 360;
      } else {
        deltaSmallH = diff + 360;
      }
    }
    final deltaBigH =
        2 * math.sqrt(c1Prime * c2Prime) * math.sin(_radians(deltaSmallH) / 2);

    final lBar = (l + other.l) / 2;
    final cBarPrime = (c1Prime + c2Prime) / 2;

    double hBarPrime;
    if (c1Prime * c2Prime == 0) {
      hBarPrime = h1Prime + h2Prime;
    } else if ((h1Prime - h2Prime).abs() <= 180) {
      hBarPrime = (h1Prime + h2Prime) / 2;
    } else if (h1Prime + h2Prime < 360) {
      hBarPrime = (h1Prime + h2Prime + 360) / 2;
    } else {
      hBarPrime = (h1Prime + h2Prime - 360) / 2;
    }

    final t =
        1 -
        0.17 * math.cos(_radians(hBarPrime - 30)) +
        0.24 * math.cos(_radians(2 * hBarPrime)) +
        0.32 * math.cos(_radians(3 * hBarPrime + 6)) -
        0.20 * math.cos(_radians(4 * hBarPrime - 63));

    final deltaTheta =
        30 * math.exp(-((hBarPrime - 275) / 25) * ((hBarPrime - 275) / 25));
    final cBarPrime7 = _pow7(cBarPrime);
    final rc = 2 * math.sqrt(cBarPrime7 / (cBarPrime7 + _twentyFive7));

    final lBarMinus50 = lBar - 50;
    final sl =
        1 +
        (0.015 * lBarMinus50 * lBarMinus50) /
            math.sqrt(20 + lBarMinus50 * lBarMinus50);
    final sc = 1 + 0.045 * cBarPrime;
    final sh = 1 + 0.015 * cBarPrime * t;
    final rt = -math.sin(_radians(2 * deltaTheta)) * rc;

    final lTerm = deltaL / sl;
    final cTerm = deltaC / sc;
    final hTerm = deltaBigH / sh;

    return math.sqrt(
      lTerm * lTerm + cTerm * cTerm + hTerm * hTerm + rt * cTerm * hTerm,
    );
  }

  static double _hueDegrees(double y, double x) {
    if (x == 0 && y == 0) return 0;
    final degrees = math.atan2(y, x) * 180 / math.pi;
    return degrees < 0 ? degrees + 360 : degrees;
  }

  static double _radians(double degrees) => degrees * math.pi / 180;

  /// `x^7` written out. `math.pow` is a general routine and dominated the
  /// CIEDE2000 profile.
  static double _pow7(double x) {
    final x2 = x * x;
    final x4 = x2 * x2;
    return x4 * x2 * x;
  }

  static const double _twentyFive7 = 6103515625.0; // 25^7

  Lab operator +(Lab other) => Lab(l + other.l, a + other.a, b + other.b);

  Lab operator -(Lab other) => Lab(l - other.l, a - other.a, b - other.b);

  Lab scaledBy(double factor) => Lab(l * factor, a * factor, b * factor);

  /// Converts back to sRGB, clamping out-of-gamut results.
  ///
  /// Only used by tests and diagnostics; the pipeline never needs to go back.
  List<int> toRgb() {
    final fy = (l + 16.0) / 116.0;
    final fx = fy + a / 500.0;
    final fz = fy - b / 200.0;

    final x = 0.95047 * _fInv(fx);
    final y = 1.0 * _fInv(fy);
    final z = 1.08883 * _fInv(fz);

    final lr = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z;
    final lg = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z;
    final lb = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z;

    return <int>[_toSrgb(lr), _toSrgb(lg), _toSrgb(lb)];
  }

  @override
  bool operator ==(Object other) =>
      other is Lab && other.l == l && other.a == a && other.b == b;

  @override
  int get hashCode => Object.hash(l, a, b);

  @override
  String toString() =>
      'Lab(${l.toStringAsFixed(2)}, ${a.toStringAsFixed(2)}, '
      '${b.toStringAsFixed(2)})';

  static int _toSrgb(double linear) {
    final v = linear <= 0.0031308
        ? 12.92 * linear
        : 1.055 * math.pow(linear, 1 / 2.4) - 0.055;
    final scaled = (v * 255.0).round();
    if (scaled < 0) return 0;
    if (scaled > 255) return 255;
    return scaled;
  }
}

/// A point in OkLab.
///
/// Euclidean distance here is the cheap modern alternative to CIEDE2000: it
/// keeps hue better than CIE76 on pale colours, without CIEDE2000's cost.
/// `L` is about `0..1`, not CIE76's `0..100`, so a raw OkLab distance must not
/// be compared with the dither threshold. Callers that need a threshold keep
/// storing CIE76 of the colour this metric picked.
@immutable
class OkLab {
  const OkLab(this.l, this.a, this.b);

  factory OkLab.fromRgb(int r, int g, int b) {
    final lr = _linearLut[r];
    final lg = _linearLut[g];
    final lb = _linearLut[b];

    final l = 0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb;
    final m = 0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb;
    final s = 0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb;

    final l_ = _cbrt(l);
    final m_ = _cbrt(m);
    final s_ = _cbrt(s);

    return OkLab(
      0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
      1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
      0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
    );
  }

  final double l;
  final double a;
  final double b;

  double distanceSquaredTo(OkLab other) {
    final dl = l - other.l;
    final da = a - other.a;
    final db = b - other.b;
    return dl * dl + da * da + db * db;
  }

  static double _cbrt(double x) {
    if (x <= 0) return 0;
    return math.pow(x, 1 / 3).toDouble();
  }
}
