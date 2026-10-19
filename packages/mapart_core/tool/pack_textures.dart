// Packs every block's up-face texture from the 26.1.2 jar into one atlas the
// preview can blit. Cells are 16x16.
//
// Usage, from the mapart_core package root:
//   dart run tool/pack_textures.dart [jar]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:mapart_core/mapart_core.dart';

void main(List<String> args) {
  final jarPath = args.isNotEmpty
      ? args[0]
      : r'C:\Users\xiefuzhu\AppData\Roaming\.minecraft\versions\26.1.2\26.1.2.jar';
  final bytes = File(jarPath).readAsBytesSync();
  final palette = extractTexturePalette(
    bytes,
    source: jarPath,
    keepPixels: true,
  );

  const cell = 16;
  const columns = 64;
  final ids = <String>[];
  final cells = <Uint8List>[];
  final seen = <String>{};
  for (final entry in palette.entries) {
    final pixels = entry.pixels;
    if (pixels == null || entry.pixelWidth == 0) continue;
    if (!seen.add(entry.blockId)) continue;
    ids.add(entry.blockId);
    cells.add(_toCell(pixels, entry.pixelWidth, entry.pixelHeight, cell));
  }

  final rows = (ids.length + columns - 1) ~/ columns;
  final atlas = img.Image(width: columns * cell, height: rows * cell);
  img.fill(atlas, color: img.ColorRgba8(0, 0, 0, 0));
  for (var i = 0; i < cells.length; i++) {
    final ox = (i % columns) * cell;
    final oy = (i ~/ columns) * cell;
    final cellBytes = cells[i];
    for (var y = 0; y < cell; y++) {
      for (var x = 0; x < cell; x++) {
        final o = (y * cell + x) * 4;
        atlas.setPixelRgba(
          ox + x,
          oy + y,
          cellBytes[o],
          cellBytes[o + 1],
          cellBytes[o + 2],
          cellBytes[o + 3],
        );
      }
    }
  }

  final pngPath = 'assets/colors/block_textures.png';
  final jsonPath = 'assets/colors/block_textures.json';
  File(pngPath).writeAsBytesSync(img.encodePng(atlas));
  File(jsonPath).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'cell': cell,
      'columns': columns,
      'blocks': {for (var i = 0; i < ids.length; i++) ids[i]: i},
    }),
  );
  stdout.writeln('packed ${ids.length} textures into $pngPath '
      '(${(File(pngPath).lengthSync() / 1024).toStringAsFixed(0)} kB)');
}

Uint8List _toCell(Uint8List rgba, int width, int height, int cell) {
  final out = Uint8List(cell * cell * 4);
  for (var y = 0; y < cell; y++) {
    for (var x = 0; x < cell; x++) {
      final sx = width == cell ? x : (x * width) ~/ cell;
      final sy = height == cell ? y : (y * height) ~/ cell;
      final from = (sy * width + sx) * 4;
      final to = (y * cell + x) * 4;
      out[to] = rgba[from];
      out[to + 1] = rgba[from + 1];
      out[to + 2] = rgba[from + 2];
      out[to + 3] = rgba[from + 3];
    }
  }
  return out;
}
