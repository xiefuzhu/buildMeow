// How far is each source pixel from the nearest map colour, and does the
// dither's ramp fire where it says it does?
//
// Usage, from the mapart_core package root:
//   dart run tool/dither_probe.dart <source image> [mapsX] [mapsY]
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:mapart_core/mapart_core.dart';

void main(List<String> args) {
  final sourcePath = args.isNotEmpty
      ? args[0]
      : r'C:\Users\xiefuzhu\Pictures\b_4f2f34e84abd093becc060a0ecc35f35.jpg';
  final mapsX = args.length > 1 ? int.parse(args[1]) : 2;
  final mapsY = args.length > 2 ? int.parse(args[2]) : 2;

  final table = ColorTable.fromJson(
    jsonDecode(File('assets/colors/mapartcraft.colors.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final palette = Palette.blocks(table, '1.20');
  final versions = VersionTable.fromJson(
    jsonDecode(File('assets/colors/versions.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final plan = suggestHeightPlan(versions.latest);

  final decoded = img.decodeImage(File(sourcePath).readAsBytesSync())!;
  final grid = fitToGrid(
    _toRgbaImage(decoded),
    mapsX * 128,
    mapsY * 128,
    mode: CropMode.cover,
    background: const Rgb(255, 255, 255),
  );
  stdout.writeln('grid ${grid.width}x${grid.height}');

  // The three shades of every colour, which is what the quantizer may pick.
  final tones = <(int, ShadeTier, Lab)>[];
  for (var i = 0; i < palette.length; i++) {
    for (final tier in ShadeTier.staircase) {
      final t = palette.entries[i].tone(tier);
      tones.add((i, tier, Lab.fromRgb(t.r, t.g, t.b)));
    }
  }

  // How far the *source* pixel is from the best the palette can do. This is the
  // quantity the documented ramp is supposed to be driven by.
  final histogram = List<int>.filled(40, 0);
  var nearWhiteDelta = 0.0, nearWhiteN = 0;
  var blueDelta = 0.0, blueN = 0;
  for (var y = 0; y < grid.height; y++) {
    for (var x = 0; x < grid.width; x++) {
      final p = grid.pixelAt(x, y);
      final lab = Lab.fromRgb(p.r, p.g, p.b);
      var best = double.infinity;
      for (final (_, _, tone) in tones) {
        final d = lab.distanceTo(tone);
        if (d < best) best = d;
      }
      histogram[best.round().clamp(0, 39)]++;
      final minChannel = [p.r, p.g, p.b].reduce((a, b) => a < b ? a : b);
      if (minChannel >= 228) {
        nearWhiteDelta += best;
        nearWhiteN++;
      }
      if (p.b > p.r + 30 && p.b > 120 && p.b < 230) {
        blueDelta += best;
        blueN++;
      }
    }
  }

  stdout.writeln('\nsource pixel -> nearest of the 180 staircase colours');
  stdout.writeln('  mean deltaE for near-white pixels: '
      '${(nearWhiteDelta / nearWhiteN).toStringAsFixed(2)} (n=$nearWhiteN)');
  stdout.writeln('  mean deltaE for blue-ish pixels:   '
      '${(blueDelta / blueN).toStringAsFixed(2)} (n=$blueN)');
  stdout.writeln('  histogram of deltaE:');
  for (var i = 0; i < histogram.length; i++) {
    if (histogram[i] == 0) continue;
    stdout.writeln('    ${i.toString().padLeft(2)}..${i + 1}: '
        '${histogram[i].toString().padLeft(6)}');
  }

  for (final variant in <(String, QuantizeOptions)>[
    ('plain', const QuantizeOptions()),
    ('dither thr8 (app)', const QuantizeOptions(
      dither: DitherMode.floydSteinberg,
      ditherThreshold: 8,
    )),
    ('dither thr8 + budget', QuantizeOptions(
      dither: DitherMode.floydSteinberg,
      ditherThreshold: 8,
      driftBudget: plan.driftBudget,
    )),
    ('dither thr0', const QuantizeOptions(
      dither: DitherMode.floydSteinberg,
      ditherThreshold: 0,
    )),
    ('dither thr16', const QuantizeOptions(
      dither: DitherMode.floydSteinberg,
      ditherThreshold: 16,
    )),
  ]) {
    final quantized = quantize(
      source: grid,
      palette: palette,
      options: variant.$2,
    );
    final solution = solveHeights(quantized: quantized);
    final rendered = renderMap(
      solution: solution,
      quantized: quantized,
      palette: palette,
    );
    stdout.writeln('\n== ${variant.$1} ==');
    _report(grid, rendered);
  }
}

void _report(RgbaImage target, RgbaImage rendered) {
  var tr = 0, tg = 0, tb = 0, rr = 0, rg = 0, rb = 0;
  var n = 0;
  // Near-white pixels: the shirt and the pillow, which the palette can hit
  // exactly with White Wool bright.
  var wtn = 0, wtr = 0, wtg = 0, wtb = 0, wrr = 0, wrg = 0, wrb = 0;
  var whiteKept = 0;
  // Mid-tone pixels, where dithering is supposed to earn its keep.
  var mtn = 0, mtr = 0, mtg = 0, mtb = 0, mrr = 0, mrg = 0, mrb = 0;

  for (var y = 0; y < target.height; y++) {
    for (var x = 0; x < target.width; x++) {
      final t = target.pixelAt(x, y);
      final r = rendered.pixelAt(x, y);
      tr += t.r; tg += t.g; tb += t.b;
      rr += r.r; rg += r.g; rb += r.b;
      n++;

      final minChannel = [t.r, t.g, t.b].reduce((a, b) => a < b ? a : b);
      if (minChannel >= 228) {
        wtn++;
        wtr += t.r; wtg += t.g; wtb += t.b;
        wrr += r.r; wrg += r.g; wrb += r.b;
        if (r.r >= 250 && r.g >= 250 && r.b >= 250) whiteKept++;
      }

      final luma = (0.2126 * t.r + 0.7152 * t.g + 0.0722 * t.b);
      if (luma >= 100 && luma <= 200) {
        mtn++;
        mtr += t.r; mtg += t.g; mtb += t.b;
        mrr += r.r; mrg += r.g; mrb += r.b;
      }
    }
  }

  void line(String label, int cnt, int a, int b, int c, int d, int e, int f) {
    if (cnt == 0) {
      stdout.writeln('  $label: none');
      return;
    }
    final tm = [a / cnt, b / cnt, c / cnt];
    final rm = [d / cnt, e / cnt, f / cnt];
    final delta = [
      rm[0] - tm[0],
      rm[1] - tm[1],
      rm[2] - tm[2],
    ];
    stdout.writeln(
      '  ${label.padRight(14)} n=${cnt.toString().padLeft(6)}  '
      'target=${_rgb(tm)}  rendered=${_rgb(rm)}  '
      'bias=${_rgb(delta, signed: true)}  '
      'deltaE=${_deltaE(tm, rm).toStringAsFixed(2)}',
    );
  }

  line('whole image', n, tr, tg, tb, rr, rg, rb);
  line('near-white', wtn, wtr, wtg, wtb, wrr, wrg, wrb);
  line('mid-tone', mtn, mtr, mtg, mtb, mrr, mrg, mrb);
  stdout.writeln(
    '  near-white pixels rendered as pure white: '
    '$whiteKept / $wtn (${(100 * whiteKept / wtn).toStringAsFixed(1)}%)',
  );
}

String _rgb(List<double> c, {bool signed = false}) {
  final out = <String>[];
  for (final v in c) {
    final rounded = v.round();
    out.add(signed && rounded >= 0 ? '+$rounded' : '$rounded');
  }
  return '(${out.join(',')})';
}

double _deltaE(List<double> a, List<double> b) {
  final la = Lab.fromRgb(a[0].round(), a[1].round(), a[2].round());
  final lb = Lab.fromRgb(b[0].round(), b[1].round(), b[2].round());
  return la.distanceTo(lb);
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
