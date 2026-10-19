// Lists the brightest blocks in the matcher's palette, so a cast can be seen
// rather than guessed. Prints the 16 brightest by Rec.709 luma, then the same
// sorted by how blue-shifted they are.
//
// Usage, from the mapart_core package root:
//   dart run tool/brightest_blocks.dart
import 'dart:convert';
import 'dart:io';

void main() {
  final kept = (jsonDecode(File('assets/colors/kept_blocks.json').readAsStringSync())
          as List<Object?>)
      .cast<String>()
      .toSet();
  final json =
      jsonDecode(
            File('assets/colors/texture_palette_26_1_2.json').readAsStringSync(),
          )
          as Map<String, dynamic>;

  const emptyFace = {
    'notAFullCube',
    'multipart',
    'noGeometry',
    'translucent',
    'animated',
    'undecodable',
    'noTexture',
  };

  final rows = <_Row>[];
  for (final raw in json['blocks'] as List) {
    final block = raw as Map<String, dynamic>;
    final srgb = block['srgb'];
    if (srgb is! List || srgb.length != 3) continue;
    final id = block['block'] as String;
    if (id.contains('glass') || id == 'beacon') continue;
    if (block['excluded'] == 'translucent') continue;
    final opaque = block['opaquePixels'];
    if (opaque is num && opaque < 200) continue;
    if (emptyFace.contains(block['excluded'])) continue;
    if (!kept.contains(id)) continue;
    final r = (srgb[0] as num).toInt();
    final g = (srgb[1] as num).toInt();
    final b = (srgb[2] as num).toInt();
    rows.add(_Row(id, r, g, b, (block['noisiness'] as num).toDouble()));
  }

  stdout.writeln('palette ${rows.length} blocks (kept_blocks filter applied)');
  stdout.writeln('');
  stdout.writeln('brightest 16 by Rec.709 luma:');
  stdout.writeln(
    '  ${'block'.padRight(30)}${'srgb'.padLeft(18)}'
    '${'luma'.padLeft(7)}${'b-r'.padLeft(6)}${'noise'.padLeft(7)}',
  );
  final byLuma = [...rows]..sort((a, b) => b.luma.compareTo(a.luma));
  for (final row in byLuma.take(16)) {
    stdout.writeln(
      '  ${row.id.padRight(30)}${row.hex.padLeft(18)}'
      '${row.luma.toStringAsFixed(1).padLeft(7)}'
      '${(row.b - row.r).toString().padLeft(6)}'
      '${row.noise.toStringAsFixed(1).padLeft(7)}',
    );
  }

  stdout.writeln('');
  stdout.writeln('brightest 8 whose blue channel leads red by 3 or more:');
  final bluish = byLuma.where((r) => r.b - r.r >= 3).take(8).toList();
  if (bluish.isEmpty) {
    stdout.writeln('  none');
  } else {
    for (final row in bluish) {
      stdout.writeln(
        '  ${row.id.padRight(30)}${row.hex.padLeft(18)}'
        '${row.luma.toStringAsFixed(1).padLeft(7)}'
        '${(row.b - row.r).toString().padLeft(6)}'
        '${row.noise.toStringAsFixed(1).padLeft(7)}',
      );
    }
  }

  stdout.writeln('');
  stdout.writeln('nearest to pure white #ffffff:');
  final byWhite = [...rows]
    ..sort((a, b) => a.distanceTo(255, 255, 255).compareTo(
      b.distanceTo(255, 255, 255),
    ));
  for (final row in byWhite.take(8)) {
    stdout.writeln(
      '  ${row.id.padRight(30)}${row.hex.padLeft(18)}'
      '${row.distanceTo(255, 255, 255).toStringAsFixed(1).padLeft(7)}'
      '${'b-r ${row.b - row.r}'.padLeft(9)}',
    );
  }
}

class _Row {
  _Row(this.id, this.r, this.g, this.b, this.noise);

  final String id;
  final int r;
  final int g;
  final int b;
  final double noise;

  double get luma => 0.2126 * r + 0.7152 * g + 0.0722 * b;

  String get hex =>
      '#${r.toRadixString(16).padLeft(2, '0')}'
      '${g.toRadixString(16).padLeft(2, '0')}'
      '${b.toRadixString(16).padLeft(2, '0')}';

  double distanceTo(int rr, int gg, int bb) {
    final dr = (r - rr).toDouble();
    final dg = (g - gg).toDouble();
    final db = (b - bb).toDouble();
    return (dr * dr + dg * dg + db * db) / 3;
  }
}
