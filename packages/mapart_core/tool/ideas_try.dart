// Tries the remaining ways to render a pastel that no map colour actually is,
// and writes a strip: source, dye-hue flat, halftone, current chroma flat.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:mapart_core/mapart_core.dart';

void main() {
  final decoded = img.decodeImage(File('tool/synthetic.png').readAsBytesSync())!;
  final grid = fitToGrid(
    _toRgba(decoded),
    128,
    128,
    mode: CropMode.cover,
    background: const Rgb(255, 255, 255),
  );

  final table = ColorTable.fromJson(
    jsonDecode(File('assets/colors/mapartcraft.colors.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final palette = Palette.blocks(table, '1.20');
  final tones = <_Tone>[];
  final seen = <int>{};
  for (final entry in palette.entries) {
    for (final tier in ShadeTier.staircase) {
      final c = entry.tone(tier);
      final key = (c.r << 16) | (c.g << 8) | c.b;
      if (!seen.add(key)) continue;
      tones.add(_Tone('${entry.name} ${tier.name}', c));
    }
  }

  const hair = Rgb(178, 235, 240);
  stdout.writeln('closest by dE:');
  final byDe = [...tones]..sort((a, b) => a.lab.distanceTo(_Tone.labOf(hair)).compareTo(b.lab.distanceTo(_Tone.labOf(hair))));
  for (final t in byDe.take(6)) {
    stdout.writeln('  ${t.label.padRight(28)} ${t.color}  dE ${t.lab.distanceTo(_Tone.labOf(hair)).toStringAsFixed(1)}  hue ${t.hue.toStringAsFixed(0)}');
  }
  stdout.writeln('closest hue among chromatic:');
  final hairHue = _Tone.labOf(hair);
  final hueOfHair = _hue(hairHue);
  final chromatic = tones.where((t) => t.chroma > 15).toList()
    ..sort((a, b) => _hueDist(a.hue, hueOfHair).compareTo(_hueDist(b.hue, hueOfHair)));
  for (final t in chromatic.take(6)) {
    stdout.writeln('  ${t.label.padRight(28)} ${t.color}  hueΔ ${_hueDist(t.hue, hueOfHair).toStringAsFixed(0)}  dE ${t.lab.distanceTo(hairHue).toStringAsFixed(1)}');
  }

  final dye = _dyeFlat(grid, tones);
  final half = _halftone(grid, tones);
  final current = _fromQuantized(
    quantize(
      source: grid,
      palette: palette,
      options: const QuantizeOptions(metric: ColorMetric.chromaWeighted),
    ),
    palette,
  );

  _report('dye hue', grid, dye);
  _report('halftone', grid, half);
  _report('chroma flat', grid, current);

  const scale = 3;
  final panels = [grid, dye, half, current];
  final strip = img.Image(
    width: grid.width * panels.length * scale + (panels.length - 1) * 4,
    height: grid.height * scale,
  );
  img.fill(strip, color: img.ColorRgb8(30, 30, 30));
  for (var i = 0; i < panels.length; i++) {
    final ox = i * (grid.width * scale + 4);
    for (var y = 0; y < grid.height; y++) {
      for (var x = 0; x < grid.width; x++) {
        final p = panels[i].pixelAt(x, y);
        for (var dy = 0; dy < scale; dy++) {
          for (var dx = 0; dx < scale; dx++) {
            strip.setPixelRgb(ox + x * scale + dx, y * scale + dy, p.r, p.g, p.b);
          }
        }
      }
    }
  }
  // Also the same strip blurred, which is what a map looks like from arm's length.
  final small = img.Image(width: grid.width * panels.length + (panels.length - 1), height: grid.height);
  img.fill(small, color: img.ColorRgb8(30, 30, 30));
  for (var i = 0; i < panels.length; i++) {
    final ox = i * (grid.width + 1);
    for (var y = 0; y < grid.height; y++) {
      for (var x = 0; x < grid.width; x++) {
        final p = panels[i].pixelAt(x, y);
        small.setPixelRgb(ox + x, y, p.r, p.g, p.b);
      }
    }
  }
  final blurred = img.gaussianBlur(small, radius: 1);
  File('out/ideas_zoom.png').writeAsBytesSync(img.encodePng(strip));
  File('out/ideas_map.png').writeAsBytesSync(img.encodePng(blurred));
  stdout.writeln('wrote out/ideas_zoom.png and out/ideas_map.png');
}

class _Tone {
  _Tone(this.label, this.color) : lab = labOf(color);
  final String label;
  final Rgb color;
  final Lab lab;
  double get chroma => math.sqrt(lab.a * lab.a + lab.b * lab.b);
  double get hue => _hue(lab);
  static Lab labOf(Rgb c) => Lab.fromRgb(c.r, c.g, c.b);
}

double _hue(Lab lab) {
  if (lab.a == 0 && lab.b == 0) return 0;
  var d = math.atan2(lab.b, lab.a) * 180 / math.pi;
  if (d < 0) d += 360;
  return d;
}

double _hueDist(double a, double b) {
  final d = (a - b).abs();
  return d > 180 ? 360 - d : d;
}

/// Nearest dye-like colour by hue, then lightness. Neutrals stay nearest-grey.
/// "Dye-like" is a base colour whose name contains Wool, Terracotta or Concrete,
/// which is the set illustrations are usually built from.
RgbaImage _dyeFlat(RgbaImage grid, List<_Tone> tones) {
  final dyes = tones.where((t) {
    final n = t.label;
    return n.contains('Wool') || n.contains('Terracotta') || n.contains('Concrete') || n.startsWith('White') || n.startsWith('Black') || n.startsWith('Gray') || n.startsWith('Light Gray');
  }).toList();
  final out = RgbaImage(grid.width, grid.height);
  for (var y = 0; y < grid.height; y++) {
    for (var x = 0; x < grid.width; x++) {
      out.setRgb(x, y, _pickDye(grid.pixelAt(x, y), dyes).color);
    }
  }
  return out;
}

_Tone _pickDye(Rgb pixel, List<_Tone> dyes) {
  final lab = Lab.fromRgb(pixel.r, pixel.g, pixel.b);
  final chroma = math.sqrt(lab.a * lab.a + lab.b * lab.b);
  if (chroma < 8) {
    return _nearest(lab, dyes);
  }
  final hue = _hue(lab);
  final chromatic = dyes.where((t) => t.chroma > 12 && _hueDist(t.hue, hue) < 35).toList();
  if (chromatic.isEmpty) return _nearest(lab, dyes);
  chromatic.sort((a, b) {
    final dh = _hueDist(a.hue, hue).compareTo(_hueDist(b.hue, hue));
    if (dh != 0) return dh;
    return (a.lab.l - lab.l).abs().compareTo((b.lab.l - lab.l).abs());
  });
  // Among the closest hue, take the one nearest in lightness.
  final bestHue = _hueDist(chromatic.first.hue, hue);
  final band = chromatic.where((t) => _hueDist(t.hue, hue) <= bestHue + 8).toList()
    ..sort((a, b) => (a.lab.l - lab.l).abs().compareTo((b.lab.l - lab.l).abs()));
  return band.first;
}

_Tone _nearest(Lab lab, List<_Tone> tones) {
  var best = tones.first;
  var bestD = double.infinity;
  for (final t in tones) {
    final d = lab.distanceTo(t.lab);
    if (d < bestD) {
      bestD = d;
      best = t;
    }
  }
  return best;
}

/// Two-colour halftone. A pastel is the mix of the nearest neutral and the
/// nearest same-hue colour; the minority colour is placed by an 8x8 blue-noise
/// mask instead of Floyd-Steinberg, so the dots don't form a checkerboard.
RgbaImage _halftone(RgbaImage grid, List<_Tone> tones) {
  final neutrals = tones.where((t) => t.chroma < 8).toList();
  final out = RgbaImage(grid.width, grid.height);
  for (var y = 0; y < grid.height; y++) {
    for (var x = 0; x < grid.width; x++) {
      final pixel = grid.pixelAt(x, y);
      final lab = Lab.fromRgb(pixel.r, pixel.g, pixel.b);
      final chroma = math.sqrt(lab.a * lab.a + lab.b * lab.b);
      final neutral = _nearest(lab, neutrals.isEmpty ? tones : neutrals);
      if (chroma < 8) {
        out.setRgb(x, y, neutral.color);
        continue;
      }
      final hue = _hue(lab);
      final chromatic = tones.where((t) => t.chroma > 15 && _hueDist(t.hue, hue) < 40).toList();
      if (chromatic.isEmpty) {
        out.setRgb(x, y, _nearest(lab, tones).color);
        continue;
      }
      chromatic.sort((a, b) => _hueDist(a.hue, hue).compareTo(_hueDist(b.hue, hue)));
      final ink = chromatic.first;
      // Fraction of the ink colour, in linear light, that lands on the target.
      final fraction = _mixFraction(pixel, neutral.color, ink.color);
      if (fraction < 0.08) {
        out.setRgb(x, y, neutral.color);
      } else if (fraction > 0.92) {
        out.setRgb(x, y, ink.color);
      } else if (_mask(x, y) < fraction) {
        out.setRgb(x, y, ink.color);
      } else {
        out.setRgb(x, y, neutral.color);
      }
    }
  }
  return out;
}

double _mixFraction(Rgb target, Rgb paper, Rgb ink) {
  double lin(int c) {
    final x = c / 255.0;
    return x <= 0.04045 ? x / 12.92 : math.pow((x + 0.055) / 1.055, 2.4).toDouble();
  }

  var bestT = 0.0;
  var bestD = double.infinity;
  final tl = Lab.fromRgb(target.r, target.g, target.b);
  for (var i = 0; i <= 20; i++) {
    final t = i / 20.0;
    int ch(int a, int b) {
      final v = lin(a) + (lin(b) - lin(a)) * t;
      final s = v <= 0.0031308 ? 12.92 * v : 1.055 * math.pow(v, 1 / 2.4) - 0.055;
      return (s * 255).round().clamp(0, 255);
    }

    final mixed = Lab.fromRgb(ch(paper.r, ink.r), ch(paper.g, ink.g), ch(paper.b, ink.b));
    final d = tl.distanceTo(mixed);
    if (d < bestD) {
      bestD = d;
      bestT = t;
    }
  }
  return bestT;
}

/// 8x8 void-and-cluster ranks in (0, 1), same construction as the quantizer.
double _mask(int x, int y) => _noise[(y & 7) * 8 + (x & 7)];

final List<double> _noise = () {
  const n = 8;
  const count = 64;
  const sigma = 1.5;
  const two = 2 * sigma * sigma;
  double energy(int x, int y, List<bool> on) {
    var e = 0.0;
    for (var yy = 0; yy < n; yy++) {
      for (var xx = 0; xx < n; xx++) {
        if (!on[yy * n + xx] || (xx == x && yy == y)) continue;
        var dx = (xx - x).abs();
        if (dx > n - dx) dx = n - dx;
        var dy = (yy - y).abs();
        if (dy > n - dy) dy = n - dy;
        e += math.exp(-(dx * dx + dy * dy) / two);
      }
    }
    return e;
  }

  final rng = math.Random(1);
  final on = List<bool>.filled(count, false);
  final rank = List<int>.filled(count, 0);
  var ones = 0;
  while (ones < count ~/ 8) {
    final i = rng.nextInt(count);
    if (!on[i]) {
      on[i] = true;
      ones++;
    }
  }
  var next = count - 1;
  while (ones > 0) {
    var bestI = 0;
    var bestE = -1.0;
    for (var i = 0; i < count; i++) {
      if (!on[i]) continue;
      final e = energy(i % n, i ~/ n, on);
      if (e > bestE) {
        bestE = e;
        bestI = i;
      }
    }
    rank[bestI] = next--;
    on[bestI] = false;
    ones--;
  }
  while (next >= 0) {
    var bestI = 0;
    var bestE = double.infinity;
    for (var i = 0; i < count; i++) {
      if (on[i]) continue;
      final e = energy(i % n, i ~/ n, on);
      if (e < bestE) {
        bestE = e;
        bestI = i;
      }
    }
    rank[bestI] = next--;
    on[bestI] = true;
  }
  return [for (var i = 0; i < count; i++) (rank[i] + 0.5) / count];
}();

RgbaImage _fromQuantized(QuantizedImage quantized, Palette palette) {
  final out = RgbaImage(quantized.width, quantized.height);
  for (var y = 0; y < quantized.height; y++) {
    for (var x = 0; x < quantized.width; x++) {
      out.setRgb(x, y, bestColorAt(quantized: quantized, palette: palette, x: x, y: y));
    }
  }
  return out;
}

void _report(String label, RgbaImage target, RgbaImage got) {
  var sum = 0.0;
  final used = <int>{};
  for (var y = 0; y < target.height; y++) {
    for (var x = 0; x < target.width; x++) {
      final a = target.pixelAt(x, y);
      final b = got.pixelAt(x, y);
      sum += Lab.fromRgb(a.r, a.g, a.b).distanceTo(Lab.fromRgb(b.r, b.g, b.b));
      used.add((b.r << 16) | (b.g << 8) | b.b);
    }
  }
  stdout.writeln('$label  mean dE ${(sum / (target.width * target.height)).toStringAsFixed(2)}  colours ${used.length}');
}


RgbaImage _toRgba(img.Image source) {
  final out = RgbaImage(source.width, source.height);
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final p = source.getPixel(x, y);
      out.setPixel(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(), p.a.toInt());
    }
  }
  return out;
}
