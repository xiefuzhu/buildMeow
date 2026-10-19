// Why does this rectangle render the way it does?
//
// Prints, for a rectangle of the map grid, the mean source colour, the mean
// rendered colour, and which palette tones the render actually used and how
// often — so a "wrong colour patch" can be told apart from "the palette cannot
// reach this colour and is mixing two others to fake it".
//
// Usage, from the mapart_core package root:
//   dart run tool/region_probe.dart <image> <x0> <y0> <x1> <y1> [threshold]
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:mapart_core/mapart_core.dart';

void main(List<String> args) {
  final sourcePath = args[0];
  final x0 = int.parse(args[1]);
  final y0 = int.parse(args[2]);
  final x1 = int.parse(args[3]);
  final y1 = int.parse(args[4]);
  final threshold = args.length > 5 ? double.parse(args[5]) : 8.0;

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
    128,
    128,
    mode: CropMode.cover,
    background: const Rgb(255, 255, 255),
  );

  final quantized = quantize(
    source: grid,
    palette: palette,
    options: QuantizeOptions(
      dither: DitherMode.floydSteinberg,
      ditherThreshold: threshold,
      driftBudget: plan.driftBudget,
    ),
  );
  final solution = solveHeights(
    quantized: quantized,
    options: HeightSolverOptions(baseHeight: plan.baseHeight, flatnessWeight: 0),
  );
  final rendered = renderMap(
    solution: solution,
    quantized: quantized,
    palette: palette,
  );

  var sr = 0, sg = 0, sb = 0, rr = 0, rg = 0, rb = 0, n = 0;
  final used = <String, int>{};
  final sourceOf = <String, List<int>>{};
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final s = grid.pixelAt(x, y);
      final r = rendered.pixelAt(x, y);
      sr += s.r; sg += s.g; sb += s.b;
      rr += r.r; rg += r.g; rb += r.b;
      n++;
      final key = _hex(r);
      used[key] = (used[key] ?? 0) + 1;
      final acc = sourceOf.putIfAbsent(key, () => [0, 0, 0, 0]);
      acc[0] += s.r; acc[1] += s.g; acc[2] += s.b; acc[3]++;
    }
  }

  final meanSource = [sr ~/ n, sg ~/ n, sb ~/ n];
  final meanRendered = [rr ~/ n, rg ~/ n, rb ~/ n];
  stdout.writeln('rect ($x0,$y0)..($x1,$y1)  $n pixels  threshold=$threshold');
  stdout.writeln('  mean source   ${_hexList(meanSource)}');
  stdout.writeln('  mean rendered ${_hexList(meanRendered)}');
  stdout.writeln('  mean deltaE   '
      '${_deltaE(meanSource, meanRendered).toStringAsFixed(2)}');
  stdout.writeln('  distinct rendered colours: ${used.length}');
  final entries = used.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in entries.take(10)) {
    final acc = sourceOf[e.key]!;
    final srcMean = [acc[0] ~/ acc[3], acc[1] ~/ acc[3], acc[2] ~/ acc[3]];
    stdout.writeln('    ${e.key}  x${e.value.toString().padLeft(4)}'
        '  (${(100 * e.value / n).toStringAsFixed(0)}%)'
        '  source there ${_hexList(srcMean)}');
  }
  // What the palette could have done, ignoring the dither entirely.
  stdout.writeln('  nearest single palette tone to the mean source:');
  var best = double.infinity;
  var bestLabel = '';
  for (var i = 0; i < palette.length; i++) {
    for (final tier in ShadeTier.staircase) {
      final t = palette.entries[i].tone(tier);
      final d = _deltaE(meanSource, [t.r, t.g, t.b]);
      if (d < best) {
        best = d;
        bestLabel = '${palette.entries[i].blockName} ${tier.name} ${_hex(t)}';
      }
    }
  }
  stdout.writeln('    $bestLabel  dE ${best.toStringAsFixed(2)}');
}

String _hex(Rgb c) =>
    '#${c.r.toRadixString(16).padLeft(2, '0')}'
    '${c.g.toRadixString(16).padLeft(2, '0')}'
    '${c.b.toRadixString(16).padLeft(2, '0')}';

String _hexList(List<int> c) =>
    '#${c[0].toRadixString(16).padLeft(2, '0')}'
    '${c[1].toRadixString(16).padLeft(2, '0')}'
    '${c[2].toRadixString(16).padLeft(2, '0')}';

double _deltaE(List<int> a, List<int> b) => Lab.fromRgb(a[0], a[1], a[2])
    .distanceTo(Lab.fromRgb(b[0], b[1], b[2]));

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
