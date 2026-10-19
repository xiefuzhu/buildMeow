// Generates a synthetic flat-colour test image that mimics the kind of
// picture that showed the checkerboard problem: pale skin, light-cyan hair,
// a dark navy bow, pale yellow stars, on white. Flat fills, no texture.
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final im = img.Image(width: 256, height: 256);
  img.fill(im, color: img.ColorRgb8(255, 255, 255));

  // Hair: light cyan, big rounded block on top.
  img.fillRect(
    im,
    x1: 48,
    y1: 16,
    x2: 208,
    y2: 200,
    color: img.ColorRgb8(178, 235, 240),
  );
  // Face: pale pink skin.
  img.fillRect(
    im,
    x1: 76,
    y1: 70,
    x2: 180,
    y2: 160,
    color: img.ColorRgb8(253, 234, 228),
  );
  // Dress: light grey.
  img.fillRect(
    im,
    x1: 88,
    y1: 160,
    x2: 168,
    y2: 236,
    color: img.ColorRgb8(216, 220, 226),
  );
  // Bow: dark navy.
  img.fillRect(
    im,
    x1: 108,
    y1: 148,
    x2: 148,
    y2: 172,
    color: img.ColorRgb8(58, 58, 85),
  );
  // Stars: pale yellow.
  img.fillRect(
    im,
    x1: 8,
    y1: 100,
    x2: 30,
    y2: 122,
    color: img.ColorRgb8(250, 240, 180),
  );
  img.fillRect(
    im,
    x1: 224,
    y1: 40,
    x2: 246,
    y2: 62,
    color: img.ColorRgb8(250, 240, 180),
  );

  File('tool/synthetic.png').writeAsBytesSync(img.encodePng(im));
  stdout.writeln('wrote tool/synthetic.png');
}
