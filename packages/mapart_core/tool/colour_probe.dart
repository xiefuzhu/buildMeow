// Probes where the palette loses fidelity.
//
// 1. Dumps every achievable colour, so gaps and near-duplicates are visible.
// 2. Takes the dominant colours of a picture and shows the best match for each,
//    which is where the visible damage comes from.
//
// Usage: dart run tool/colour_probe.dart [source image] [how many dominant colours]
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:mapart_core/mapart_core.dart';

String hex(Rgb c) =>
    '#${c.r.toRadixString(16).padLeft(2, '0')}'
    '${c.g.toRadixString(16).padLeft(2, '0')}'
    '${c.b.toRadixString(16).padLeft(2, '0')}';

void main(List<String> args) {
  final sourcePath = args.isNotEmpty
      ? args[0]
      : r'C:\Users\xiefuzhu\Pictures\B077CD3898AD5AA5511D581BD5CDFD0C.jpg';
  final topN = args.length > 1 ? int.parse(args[1]) : 24;

  final table = ColorTable.fromJson(
    jsonDecode(File('assets/colors/mapartcraft.colors.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final palette = Palette.select(table, '1.20');

  // Every achievable colour, with its source colour and shade.
  final achievable = <_Swatch>[];
  for (final entry in palette.entries) {
    for (final tier in ShadeTier.staircase) {
      final tone = entry.tone(tier);
      achievable.add(
        _Swatch(
          tone,
          Lab.fromRgb(tone.r, tone.g, tone.b),
          '${entry.name} ${tier.name}',
        ),
      );
    }
  }
  stdout.writeln('achievable colours: ${achievable.length}');
  stdout.writeln('');

  _reportGaps(achievable);
  _reportCoverage(achievable);
  _reportImage(sourcePath, topN, achievable);
}

/// The closest pairs in the palette. Anything very close is a wasted slot.
void _reportGaps(List<_Swatch> achievable) {
  final closest = <(double, String, String)>[];
  for (var i = 0; i < achievable.length; i++) {
    for (var j = i + 1; j < achievable.length; j++) {
      final d = achievable[i].lab.distanceTo(achievable[j].lab);
      closest.add((d, achievable[i].label, achievable[j].label));
    }
  }
  closest.sort((a, b) => a.$1.compareTo(b.$1));
  stdout.writeln('closest distinct pairs (a near-duplicate is a wasted slot):');
  for (final pair in closest.take(12)) {
    stdout.writeln(
      '    dE ${pair.$1.toStringAsFixed(2).padLeft(5)}  '
      '${pair.$2}  <->  ${pair.$3}',
    );
  }
  stdout.writeln('');
}

/// The nearest neighbour distance for each colour. Large values mean a region
/// of colour space the palette cannot reach.
void _reportCoverage(List<_Swatch> achievable) {
  final isolated = <(double, String)>[];
  for (var i = 0; i < achievable.length; i++) {
    var best = double.infinity;
    for (var j = 0; j < achievable.length; j++) {
      if (i == j) continue;
      final d = achievable[i].lab.distanceTo(achievable[j].lab);
      if (d < best) best = d;
    }
    isolated.add((best, achievable[i].label));
  }
  isolated.sort((a, b) => b.$1.compareTo(a.$1));
  stdout.writeln('most isolated colours (large gap around them):');
  for (final item in isolated.take(10)) {
    stdout.writeln(
      '    gap ${item.$1.toStringAsFixed(1).padLeft(5)}  ${item.$2}',
    );
  }
  stdout.writeln('');
}

/// The colours a picture is actually made of, and how well each is served.
void _reportImage(
  String sourcePath,
  int topN,
  List<_Swatch> achievable,
) {
  final decoded = img.decodeImage(File(sourcePath).readAsBytesSync());
  if (decoded == null) {
    stderr.writeln('could not decode $sourcePath');
    exitCode = 1;
    return;
  }

  // Quantise the source to 4 bits per channel and count, which is enough to
  // find the flat regions an illustration is built from.
  final counts = <int, int>{};
  for (var y = 0; y < decoded.height; y++) {
    for (var x = 0; x < decoded.width; x++) {
      final p = decoded.getPixel(x, y);
      final key =
          ((p.r.toInt() >> 4) << 8) | ((p.g.toInt() >> 4) << 4) |
          (p.b.toInt() >> 4);
      counts[key] = (counts[key] ?? 0) + 1;
    }
  }
  final total = decoded.width * decoded.height;
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  stdout.writeln('dominant colours of the picture, and their best match:');
  stdout.writeln(
    '    ${'share'.padLeft(6)}  ${'source'.padRight(9)}'
    '${'match'.padRight(9)}${'dE'.padLeft(6)}  matched to',
  );

  final worst = <(double, int)>[];
  for (final entry in sorted.take(topN)) {
    final key = entry.key;
    final r = ((key >> 8) & 0xF) << 4 | 8;
    final g = ((key >> 4) & 0xF) << 4 | 8;
    final b = (key & 0xF) << 4 | 8;
    final lab = Lab.fromRgb(r, g, b);

    var best = achievable.first;
    var bestDistance = double.infinity;
    for (final swatch in achievable) {
      final d = lab.distanceTo(swatch.lab);
      if (d < bestDistance) {
        bestDistance = d;
        best = swatch;
      }
    }
    final share = 100 * entry.value / total;
    stdout.writeln(
      '    ${share.toStringAsFixed(1).padLeft(5)}%  ${hex(Rgb(r, g, b)).padRight(9)}'
      '${hex(best.color).padRight(9)}'
      '${bestDistance.toStringAsFixed(1).padLeft(6)}  ${best.label}',
    );
    worst.add((bestDistance, entry.value));
  }

  // Weighted by how much of the picture each colour covers: this is the mean
  // loss the picture will actually suffer.
  final weighted = worst.fold<double>(
    0,
    (sum, item) => sum + item.$1 * item.$2,
  );
  final covered = worst.fold<int>(0, (sum, item) => sum + item.$2);
  stdout.writeln('');
  stdout.writeln(
    '    area-weighted mean dE over the top $topN colours: '
    '${(weighted / covered).toStringAsFixed(2)} '
    '(covering ${(100 * covered / total).toStringAsFixed(1)}% of pixels)',
  );
  stdout.writeln('');
  _reportHueGaps(achievable);
}

/// Which hue angles have no palette colour, measured in Lab.
void _reportHueGaps(List<_Swatch> achievable) {
  const bins = 36;
  final nearest = List<double>.filled(bins, double.infinity);
  final nearestLabel = List<String>.filled(bins, '');

  for (var bin = 0; bin < bins; bin++) {
    final angle = (bin + 0.5) * 360 / bins;
    for (final chroma in <double>[20, 40, 60]) {
      final rad = angle * math.pi / 180;
      // A mid-lightness sample at this hue, which is where illustrations live.
      final lab = Lab(65, chroma * math.cos(rad), chroma * math.sin(rad));
      for (final swatch in achievable) {
        final d = lab.distanceTo(swatch.lab);
        if (d < nearest[bin]) {
          nearest[bin] = d;
          nearestLabel[bin] = swatch.label;
        }
      }
    }
  }

  stdout.writeln('hue coverage at L*=65, chroma 20/40/60:');
  for (var bin = 0; bin < bins; bin += 3) {
    final angle = ((bin + 0.5) * 360 / bins).round();
    final bar = '#' * (nearest[bin] / 3).round().clamp(0, 40);
    stdout.writeln(
      '    ${angle.toString().padLeft(3)}deg  '
      '${nearest[bin].toStringAsFixed(1).padLeft(5)}  $bar',
    );
  }
}

class _Swatch {
  _Swatch(this.color, this.lab, this.label);

  final Rgb color;
  final Lab lab;
  final String label;
}
