// Converts the synthetic chibi once with the map palette and once with the
// 26.1.2 texture averages, and writes a strip so the two can be looked at.
//
// Usage, from the mapart_core package root:
//   dart run tool/try_convert.dart
import 'dart:convert';
import 'dart:io';

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
  final supplement = BlockSupplement.fromJson(
    jsonDecode(File('assets/colors/block_supplement.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final palette = Palette.blocks(
    table.including(supplement, const ['26.1.2']),
    '1.20',
    gameVersion: '26.1.2',
  );

  final mapFlat = _fromQuantized(
    quantize(
      source: grid,
      palette: palette,
      options: const QuantizeOptions(
        metric: ColorMetric.chromaWeighted,
      ),
    ),
    palette,
  );
  final mapDither = _fromQuantized(
    quantize(
      source: grid,
      palette: palette,
      options: const QuantizeOptions(
        dither: DitherMode.floydSteinberg,
        metric: ColorMetric.chromaWeighted,
      ),
    ),
    palette,
  );

  final doc = jsonDecode(
    File('assets/colors/texture_palette_26_1_2.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final selected = _colors(doc['selected'] as List, 'srgb');
  final accepted = <_Swatch>[];
  final seen = <String>{};
  for (final raw in doc['blocks'] as List) {
    final block = raw as Map<String, dynamic>;
    if (block['excluded'] != null || block['srgb'] == null) continue;
    final id = block['block'] as String;
    if (!seen.add(id)) continue;
    final rgb = (block['srgb'] as List).cast<num>();
    accepted.add(_Swatch(id, Rgb(rgb[0].toInt(), rgb[1].toInt(), rgb[2].toInt())));
  }

  final texFlat = _nearest(grid, selected);
  final texDither = _diffuse(grid, selected);
  final texAll = _nearest(grid, accepted);

  _report('map flat', grid, mapFlat);
  _report('map dither', grid, mapDither);
  _report('texture selected ${selected.length}', grid, texFlat);
  _report('texture dither ${selected.length}', grid, texDither);
  _report('texture accepted ${accepted.length}', grid, texAll);

  stdout.writeln('\nhair 30,10..90,25');
  _region('map flat', grid, mapFlat, 30, 10, 90, 25);
  _region('texture selected', grid, texFlat, 30, 10, 90, 25);
  _region('texture accepted', grid, texAll, 30, 10, 90, 25);
  stdout.writeln('\nface 76,70..100,100');
  _region('map flat', grid, mapFlat, 76, 70, 100, 100);
  _region('texture selected', grid, texFlat, 76, 70, 100, 100);

  const scale = 3;
  final panels = [grid, mapFlat, mapDither, texFlat, texDither];
  final strip = img.Image(
    width: grid.width * panels.length * scale + (panels.length - 1) * 4,
    height: grid.height * scale,
  );
  img.fill(strip, color: img.ColorRgb8(40, 40, 40));
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
  File('out/try_strip.png').writeAsBytesSync(img.encodePng(strip));
  File('out/try_tex.png').writeAsBytesSync(img.encodePng(_toImage(texFlat)));
  File('out/try_map.png').writeAsBytesSync(img.encodePng(_toImage(mapFlat)));
  stdout.writeln('\nwrote out/try_strip.png  (source, map flat, map dither, '
      'texture flat, texture dither)');
}

class _Swatch {
  _Swatch(this.name, this.color) : lab = Lab.fromRgb(color.r, color.g, color.b);
  final String name;
  final Rgb color;
  final Lab lab;
}

List<_Swatch> _colors(List<dynamic> raw, String key) => [
  for (final item in raw)
    _Swatch(
      (item as Map)['block'] as String,
      Rgb(
        ((item[key] as List)[0] as num).toInt(),
        ((item[key] as List)[1] as num).toInt(),
        ((item[key] as List)[2] as num).toInt(),
      ),
    ),
];

RgbaImage _fromQuantized(QuantizedImage quantized, Palette palette) {
  final out = RgbaImage(quantized.width, quantized.height);
  for (var y = 0; y < quantized.height; y++) {
    for (var x = 0; x < quantized.width; x++) {
      out.setRgb(x, y, bestColorAt(quantized: quantized, palette: palette, x: x, y: y));
    }
  }
  return out;
}

int _best(_Swatch target, List<_Swatch> palette) {
  var best = 0;
  var bestD = double.infinity;
  for (var i = 0; i < palette.length; i++) {
    final d = target.lab.distanceTo(palette[i].lab);
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return best;
}

RgbaImage _nearest(RgbaImage grid, List<_Swatch> palette) {
  final out = RgbaImage(grid.width, grid.height);
  for (var y = 0; y < grid.height; y++) {
    for (var x = 0; x < grid.width; x++) {
      final p = grid.pixelAt(x, y);
      final i = _best(_Swatch('', p), palette);
      out.setRgb(x, y, palette[i].color);
    }
  }
  return out;
}

RgbaImage _diffuse(RgbaImage grid, List<_Swatch> palette) {
  final w = grid.width;
  final h = grid.height;
  final err = List<double>.filled(w * h * 3, 0);
  final out = RgbaImage(w, h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = y * w + x;
      final src = grid.pixelAt(x, y);
      final lab = Lab.fromRgb(src.r, src.g, src.b);
      final shifted = Lab(
        lab.l + err[p * 3],
        lab.a + err[p * 3 + 1],
        lab.b + err[p * 3 + 2],
      );
      var best = 0;
      var bestD = double.infinity;
      for (var k = 0; k < palette.length; k++) {
        final d = shifted.distanceTo(palette[k].lab);
        if (d < bestD) {
          bestD = d;
          best = k;
        }
      }
      final chosen = palette[best];
      out.setRgb(x, y, chosen.color);
      final dl = shifted.l - chosen.lab.l;
      final da = shifted.a - chosen.lab.a;
      final db = shifted.b - chosen.lab.b;
      void add(int dx, int dy, double wt) {
        final nx = x + dx;
        final ny = y + dy;
        if (nx < 0 || nx >= w || ny >= h) return;
        final q = (ny * w + nx) * 3;
        err[q] += dl * wt;
        err[q + 1] += da * wt;
        err[q + 2] += db * wt;
      }

      add(1, 0, 7 / 16);
      add(-1, 1, 3 / 16);
      add(0, 1, 5 / 16);
      add(1, 1, 1 / 16);
    }
  }
  return out;
}

void _report(String label, RgbaImage target, RgbaImage got) {
  var sum = 0.0;
  final used = <String, int>{};
  for (var y = 0; y < target.height; y++) {
    for (var x = 0; x < target.width; x++) {
      final a = target.pixelAt(x, y);
      final b = got.pixelAt(x, y);
      sum += Lab.fromRgb(a.r, a.g, a.b).distanceTo(Lab.fromRgb(b.r, b.g, b.b));
      final key = '#${b.r.toRadixString(16).padLeft(2, '0')}'
          '${b.g.toRadixString(16).padLeft(2, '0')}'
          '${b.b.toRadixString(16).padLeft(2, '0')}';
      used[key] = (used[key] ?? 0) + 1;
    }
  }
  final n = target.width * target.height;
  stdout.writeln('$label  mean dE ${(sum / n).toStringAsFixed(2)}  '
      'colours ${used.length}');
}

void _region(String label, RgbaImage target, RgbaImage got, int x0, int y0, int x1, int y1) {
  final counts = <String, int>{};
  var n = 0;
  var sr = 0, sg = 0, sb = 0, rr = 0, rg = 0, rb = 0;
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final s = target.pixelAt(x, y);
      final r = got.pixelAt(x, y);
      sr += s.r;
      sg += s.g;
      sb += s.b;
      rr += r.r;
      rg += r.g;
      rb += r.b;
      n++;
      final key = '#${r.r.toRadixString(16).padLeft(2, '0')}'
          '${r.g.toRadixString(16).padLeft(2, '0')}'
          '${r.b.toRadixString(16).padLeft(2, '0')}';
      counts[key] = (counts[key] ?? 0) + 1;
    }
  }
  final top = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  final meanS = Lab.fromRgb(sr ~/ n, sg ~/ n, sb ~/ n);
  final meanR = Lab.fromRgb(rr ~/ n, rg ~/ n, rb ~/ n);
  stdout.writeln('  $label  dE ${meanS.distanceTo(meanR).toStringAsFixed(1)}  '
      '${top.take(3).map((e) => '${e.key} ${e.value}').join('  ')}');
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
