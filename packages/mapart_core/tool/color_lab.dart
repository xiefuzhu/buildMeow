// Colour-only experiment bench for the dither/metric questions, without the
// height solver in the way: renders the (base colour, shade) each variant
// picks directly, which is what the map shows when the solver is free
// (flatnessWeight 0).
//
// Usage, from the mapart_core package root:
//   dart run tool/color_lab.dart <image> <outPrefix> <mode> [threshold]
//
// Modes:
//   flat76 / flat2k      nearest tone per pixel, CIE76 / CIEDE2000
//   fs76 / fs2k          Floyd-Steinberg, CIE76 / CIEDE2000
//   fs76serp / fs2kserp  Floyd-Steinberg with serpentine scan
//   fs76pull <f>         CIE76 FS, source first blended f toward nearest tone
//   flatw / fsw <w>      CIE76 + w * chroma-deficit penalty (hue-preserving)
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:mapart_core/mapart_core.dart';

void main(List<String> args) {
  final sourcePath = args[0];
  final prefix = args[1];
  final mode = args[2];
  final threshold = args.length > 3 ? double.parse(args[3]) : 8.0;

  final table = ColorTable.fromJson(
    jsonDecode(File('assets/colors/mapartcraft.colors.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final palette = Palette.blocks(table, '1.20');

  final decoded = img.decodeImage(File(sourcePath).readAsBytesSync())!;
  final grid = fitToGrid(
    _toRgbaImage(decoded),
    128,
    128,
    mode: CropMode.cover,
    background: const Rgb(255, 255, 255),
  );

  // Palette tones in Lab, one per (entry, tier).
  final tones = <Rgb>[];
  final toneLab = <Lab>[];
  for (var i = 0; i < palette.length; i++) {
    for (final tier in ShadeTier.staircase) {
      final t = palette.entries[i].tone(tier);
      tones.add(t);
      toneLab.add(Lab.fromRgb(t.r, t.g, t.b));
    }
  }

  final metric2k = mode.endsWith('2k') || mode.contains('2k');
  // Chroma-deficit weight, from modes like `flatw1.5`: penalises candidates
  // *less* colourful than the target, so a chromatic target is not handed to
  // a grey just because grey is close in lightness.
  var chromaW = 0.0;
  final wMatch = RegExp(r'w([\d.]+)').firstMatch(mode);
  if (wMatch != null) chromaW = double.parse(wMatch.group(1)!);
  double rank(Lab a, Lab b) {
    if (metric2k) return a.ciede2000To(b);
    final dl = a.l - b.l, da = a.a - b.a, db = a.b - b.b;
    var d = dl * dl + da * da + db * db;
    if (chromaW > 0) {
      final ct = math.sqrt(a.a * a.a + a.b * a.b);
      final cc = math.sqrt(b.a * b.a + b.b * b.b);
      final deficit = ct - cc;
      if (deficit > 0) d += chromaW * deficit * deficit;
    }
    return d;
  }

  double de76(Lab a, Lab b) {
    final dl = a.l - b.l, da = a.a - b.a, db = a.b - b.b;
    return math.sqrt(dl * dl + da * da + db * db);
  }

  final w = grid.width, h = grid.height;
  final src = List<Lab>.generate(w * h, (p) {
    final o = p * 4;
    return Lab.fromRgb(grid.bytes[o], grid.bytes[o + 1], grid.bytes[o + 2]);
  });

  // Optional "pull": blend the source toward its nearest palette tone by the
  // fraction encoded in the mode name (pull<f> -> f = pull% / 100).
  var pull = 0.0;
  final pullMatch = RegExp(r'pull(\d+)').firstMatch(mode);
  if (pullMatch != null) pull = int.parse(pullMatch.group(1)!) / 100.0;
  if (pull > 0) {
    for (var p = 0; p < src.length; p++) {
      var best = double.infinity;
      var bestI = 0;
      for (var i = 0; i < toneLab.length; i++) {
        final d = rank(src[p], toneLab[i]);
        if (d < best) {
          best = d;
          bestI = i;
        }
      }
      final near = toneLab[bestI];
      src[p] = Lab(
        src[p].l + (near.l - src[p].l) * pull,
        src[p].a + (near.a - src[p].a) * pull,
        src[p].b + (near.b - src[p].b) * pull,
      );
    }
  }

  final chosen = Int32List(w * h);
  final serp = mode.contains('serp');
  final dither = mode.startsWith('fs');

  if (!dither) {
    for (var p = 0; p < src.length; p++) {
      var best = double.infinity;
      var bestI = 0;
      for (var i = 0; i < toneLab.length; i++) {
        final d = rank(src[p], toneLab[i]);
        if (d < best) {
          best = d;
          bestI = i;
        }
      }
      chosen[p] = bestI;
    }
  } else {
    final err = Float64List(w * h * 3);
    for (var y = 0; y < h; y++) {
      final forward = !serp || y % 2 == 0;
      for (var xi = 0; xi < w; xi++) {
        final x = forward ? xi : w - 1 - xi;
        final p = y * w + x;
        final e = p * 3;
        final target = Lab(
          src[p].l + err[e],
          src[p].a + err[e + 1],
          src[p].b + err[e + 2],
        );
        var best = double.infinity;
        var bestI = 0;
        for (var i = 0; i < toneLab.length; i++) {
          final d = rank(target, toneLab[i]);
          if (d < best) {
            best = d;
            bestI = i;
          }
        }
        // Threshold on the unshifted source, like quantize.dart: inside the
        // threshold, take the flat pick and drop the carried error.
        var own = double.infinity;
        var ownI = 0;
        for (var i = 0; i < toneLab.length; i++) {
          final d = rank(src[p], toneLab[i]);
          if (d < own) {
            own = d;
            ownI = i;
          }
        }
        final ownDe = metric2k ? own : math.sqrt(own);
        if (ownDe <= threshold) {
          chosen[p] = ownI;
          continue;
        }
        chosen[p] = bestI;
        final c = toneLab[bestI];
        final dl = target.l - c.l, da = target.a - c.a, db = target.b - c.b;
        void add(int dx, int dy, double wt) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || nx >= w || ny >= h) return;
          final q = (ny * w + nx) * 3;
          err[q] += dl * wt;
          err[q + 1] += da * wt;
          err[q + 2] += db * wt;
        }

        final s = forward ? 1 : -1;
        add(s, 0, 7 / 16);
        add(-s, 1, 3 / 16);
        add(0, 1, 5 / 16);
        add(s, 1, 1 / 16);
      }
    }
  }

  // Render + report.
  final out = img.Image(width: w, height: h);
  var sum = 0.0;
  var sumBlur = 0.0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final t = tones[chosen[y * w + x]];
      out.setPixelRgb(x, y, t.r, t.g, t.b);
      sum += de76(
        Lab.fromRgb(t.r, t.g, t.b),
        Lab.fromRgb(
          grid.bytes[(y * w + x) * 4],
          grid.bytes[(y * w + x) * 4 + 1],
          grid.bytes[(y * w + x) * 4 + 2],
        ),
      );
    }
  }
  final blurred = img.gaussianBlur(img.Image.from(out), radius: 2);
  final blurredSrc = img.gaussianBlur(_toImage(grid), radius: 2);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final a = blurred.getPixel(x, y);
      final b = blurredSrc.getPixel(x, y);
      sumBlur += Lab.fromRgb(a.r.toInt(), a.g.toInt(), a.b.toInt())
          .distanceTo(Lab.fromRgb(b.r.toInt(), b.g.toInt(), b.b.toInt()));
    }
  }
  stdout.writeln('$mode  threshold=$threshold  pull=$pull  '
      'mean dE ${(sum / (w * h)).toStringAsFixed(2)}  '
      'blurred dE ${(sumBlur / (w * h)).toStringAsFixed(2)}');
  File('${prefix}_$mode.png').writeAsBytesSync(img.encodePng(out, level: 6));
}

img.Image _toImage(RgbaImage source) {
  final out = img.Image(width: source.width, height: source.height);
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final p = source.pixelAt(x, y);
      out.setPixelRgb(x, y, p.r, p.g, p.b);
    }
  }
  return out;
}

RgbaImage _toRgbaImage(img.Image source) {
  final out = RgbaImage(source.width, source.height);
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final p = source.getPixel(x, y);
      out.setPixel(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(), p.a.toInt());
    }
  }
  return out;
}
