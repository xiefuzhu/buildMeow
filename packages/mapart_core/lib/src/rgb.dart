import 'package:meta/meta.dart';

/// An opaque 8-bit-per-channel sRGB colour.
///
/// Minecraft's map colours are authored directly in sRGB, so this is the
/// storage type throughout the pipeline. Conversion to a perceptual space
/// happens only where colour distance is measured — see `lab.dart`.
@immutable
class Rgb {
  const Rgb(this.r, this.g, this.b);

  factory Rgb.fromJson(List<Object?> json) {
    if (json.length != 3) {
      throw FormatException('expected 3 channels, got ${json.length}');
    }
    int channel(Object? value) {
      if (value is! num) {
        throw FormatException('expected a channel number, got $value');
      }
      final v = value.toInt();
      if (v < 0 || v > 255) {
        throw FormatException('channel out of range: $v');
      }
      return v;
    }

    return Rgb(channel(json[0]), channel(json[1]), channel(json[2]));
  }

  final int r;
  final int g;
  final int b;

  int get packed => (0xFF << 24) | (r << 16) | (g << 8) | b;

  /// Applies [factor] (0..1) to every channel and floors, which is exactly how
  /// Minecraft derives the darker map tones from a base colour.
  Rgb scaledBy(int numerator, int denominator) => Rgb(
    (r * numerator) ~/ denominator,
    (g * numerator) ~/ denominator,
    (b * numerator) ~/ denominator,
  );

  @override
  bool operator ==(Object other) =>
      other is Rgb && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);

  @override
  String toString() => 'Rgb($r, $g, $b)';
}
