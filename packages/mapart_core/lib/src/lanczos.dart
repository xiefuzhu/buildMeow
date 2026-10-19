import 'dart:math' as math;
import 'dart:typed_data';

import 'rgba_image.dart';

/// Kernel radius of the Lanczos filter. Three lobes is the usual choice: sharp
/// without the ringing that shows up at four and above.
const int lanczosRadius = 3;

/// A single output pixel's contribution weights over a run of input pixels.
class _Contributions {
  _Contributions(this.start, this.weights);

  /// Index of the first input pixel this output pixel samples.
  final int start;

  /// Normalised weights, one per input pixel from [start] onwards.
  final Float64List weights;

  int get tapCount => weights.length;
}

double _sinc(double x) {
  if (x.abs() < 1e-12) return 1.0;
  final px = math.pi * x;
  return math.sin(px) / px;
}

double _lanczos(double x, int radius) {
  final ax = x.abs();
  if (ax >= radius) return 0.0;
  return _sinc(x) * _sinc(x / radius);
}

/// Precomputes one axis of the resample.
///
/// When [srcLength] is larger than [dstLength] the image is being shrunk and
/// the filter is widened by `srcLength / dstLength`. Without that, a big
/// downscale only looks at a couple of source pixels per output pixel and
/// aliases badly — which is exactly the common case here, since a photograph
/// may be thousands of pixels wide and the map is 128.
List<_Contributions> _buildContributions(int srcLength, int dstLength) {
  final scale = dstLength / srcLength;
  final filterScale = scale < 1.0 ? 1.0 / scale : 1.0;
  final support = lanczosRadius * filterScale;

  final out = <_Contributions>[];
  for (var i = 0; i < dstLength; i++) {
    // Centre of this output pixel in input-pixel coordinates.
    final centre = (i + 0.5) / scale;
    final first = (centre - support).floor();
    final last = (centre + support).ceil();

    final raw = Float64List(last - first + 1);
    var sum = 0.0;
    for (var j = first; j <= last; j++) {
      final w = _lanczos((j + 0.5 - centre) / filterScale, lanczosRadius);
      raw[j - first] = w;
      sum += w;
    }

    if (sum.abs() < 1e-12) {
      // Degenerate (e.g. every tap fell outside the kernel); fall back to
      // nearest neighbour so we never produce a black pixel out of nowhere.
      final nearest = centre.floor().clamp(0, srcLength - 1);
      out.add(_Contributions(nearest, Float64List.fromList(<double>[1.0])));
      continue;
    }

    for (var j = 0; j < raw.length; j++) {
      raw[j] /= sum;
    }
    out.add(_Contributions(first, raw));
  }
  return out;
}

/// Separable Lanczos resample of an RGBA buffer.
///
/// Horizontal pass into a float intermediate, then a vertical pass out to
/// bytes. Sampling past either edge replicates the edge pixel, which avoids the
/// darkened border a zero-padded kernel would leave.
RgbaImage resampleLanczos(RgbaImage src, int dstWidth, int dstHeight) {
  assert(dstWidth > 0 && dstHeight > 0);
  if (src.width == dstWidth && src.height == dstHeight) {
    return RgbaImage.fromBytes(
      src.width,
      src.height,
      Uint8List.fromList(src.bytes),
    );
  }

  final horizontal = _buildContributions(src.width, dstWidth);
  final vertical = _buildContributions(src.height, dstHeight);

  // Horizontal pass: src (w x h) -> mid (dstWidth x h), floats per channel.
  final mid = Float32List(dstWidth * src.height * 4);
  for (var y = 0; y < src.height; y++) {
    final srcRow = y * src.width * 4;
    final midRow = y * dstWidth * 4;
    for (var x = 0; x < dstWidth; x++) {
      final contribution = horizontal[x];
      final weights = contribution.weights;
      final start = contribution.start;
      var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
      for (var t = 0; t < weights.length; t++) {
        final sx = (start + t).clamp(0, src.width - 1);
        final w = weights[t];
        final o = srcRow + sx * 4;
        r += src.bytes[o] * w;
        g += src.bytes[o + 1] * w;
        b += src.bytes[o + 2] * w;
        a += src.bytes[o + 3] * w;
      }
      final m = midRow + x * 4;
      mid[m] = r;
      mid[m + 1] = g;
      mid[m + 2] = b;
      mid[m + 3] = a;
    }
  }

  // Vertical pass: mid (dstWidth x h) -> out (dstWidth x dstHeight).
  final out = RgbaImage(dstWidth, dstHeight);
  for (var y = 0; y < dstHeight; y++) {
    final contribution = vertical[y];
    final weights = contribution.weights;
    final start = contribution.start;
    final outRow = y * dstWidth * 4;
    for (var x = 0; x < dstWidth; x++) {
      var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
      for (var t = 0; t < weights.length; t++) {
        final sy = (start + t).clamp(0, src.height - 1);
        final w = weights[t];
        final m = sy * dstWidth * 4 + x * 4;
        r += mid[m] * w;
        g += mid[m + 1] * w;
        b += mid[m + 2] * w;
        a += mid[m + 3] * w;
      }
      final o = outRow + x * 4;
      out.bytes[o] = _clampByte(r);
      out.bytes[o + 1] = _clampByte(g);
      out.bytes[o + 2] = _clampByte(b);
      out.bytes[o + 3] = _clampByte(a);
    }
  }

  return out;
}

int _clampByte(double v) {
  final rounded = v.round();
  if (rounded < 0) return 0;
  if (rounded > 255) return 255;
  return rounded;
}
