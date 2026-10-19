// Splits the packed block atlas into one PNG per block, so a block can be
// dropped by deleting its file. Names are the block ids.
//
// Usage, from the mapart_core package root:
//   dart run tool/export_block_textures.dart [output directory]
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

void main(List<String> args) {
  final outDir = Directory(
    args.isNotEmpty ? args[0] : r'C:\flutter\buildMeow\方块贴图',
  );
  final atlas = img.decodePng(File('assets/colors/block_textures.png').readAsBytesSync());
  if (atlas == null) {
    stderr.writeln('could not decode block_textures.png');
    exitCode = 1;
    return;
  }
  final json =
      jsonDecode(File('assets/colors/block_textures.json').readAsStringSync())
          as Map<String, dynamic>;
  final cell = (json['cell'] as num).toInt();
  final columns = (json['columns'] as num).toInt();
  final blocks = (json['blocks'] as Map<String, dynamic>).entries.toList()
    ..sort((a, b) => (a.value as num).compareTo(b.value as num));

  if (outDir.existsSync()) {
    outDir.deleteSync(recursive: true);
  }
  outDir.createSync(recursive: true);

  // 16x16 is too small to judge in a folder view. Nearest-neighbour keeps the
  // pixels square.
  const scale = 8;
  for (final entry in blocks) {
    final id = entry.key;
    final index = (entry.value as num).toInt();
    final ox = (index % columns) * cell;
    final oy = (index ~/ columns) * cell;
    final tile = img.Image(width: cell * scale, height: cell * scale);
    for (var y = 0; y < cell; y++) {
      for (var x = 0; x < cell; x++) {
        final pixel = atlas.getPixel(ox + x, oy + y);
        img.fillRect(
          tile,
          x1: x * scale,
          y1: y * scale,
          x2: x * scale + scale - 1,
          y2: y * scale + scale - 1,
          color: img.ColorRgba8(
            pixel.r.toInt(),
            pixel.g.toInt(),
            pixel.b.toInt(),
            pixel.a.toInt(),
          ),
        );
      }
    }
    File('${outDir.path}\\$id.png').writeAsBytesSync(img.encodePng(tile));
  }

  stdout.writeln('wrote ${blocks.length} textures to ${outDir.path}');
}
