// Rebuilds the texture atlas and the colour allow-list from the folder the
// user cleaned. A png's file name is the block id. Anything deleted there is
// dropped from both the preview atlas and the matcher.
//
// Usage, from the mapart_core package root:
//   dart run tool/apply_kept_blocks.dart [folder]
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

void main(List<String> args) {
  final folder = Directory(
    args.isNotEmpty ? args[0] : r'C:\flutter\buildMeow\方块贴图',
  );
  final kept = folder
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.png'))
      .map((f) => f.uri.pathSegments.last.replaceAll(RegExp(r'\.png$'), ''))
      .toSet();

  final json =
      jsonDecode(File('assets/colors/block_textures.json').readAsStringSync())
          as Map<String, dynamic>;
  final cell = (json['cell'] as num).toInt();
  final columns = (json['columns'] as num).toInt();
  final oldBlocks = (json['blocks'] as Map<String, dynamic>).map(
    (id, index) => MapEntry(id, (index as num).toInt()),
  );
  final atlas = img.decodePng(
    File('assets/colors/block_textures.png').readAsBytesSync(),
  );
  if (atlas == null) {
    stderr.writeln('could not decode the current atlas');
    exitCode = 1;
    return;
  }

  final unknown = kept.where((id) => !oldBlocks.containsKey(id)).toList()
    ..sort();
  final ids = oldBlocks.keys.where(kept.contains).toList()
    ..sort((a, b) => oldBlocks[a]!.compareTo(oldBlocks[b]!));

  const newColumns = 64;
  final rows = (ids.length + newColumns - 1) ~/ newColumns;
  final packed = img.Image(width: newColumns * cell, height: rows * cell);
  img.fill(packed, color: img.ColorRgba8(0, 0, 0, 0));
  for (var i = 0; i < ids.length; i++) {
    final old = oldBlocks[ids[i]]!;
    final sx = (old % columns) * cell;
    final sy = (old ~/ columns) * cell;
    final dx = (i % newColumns) * cell;
    final dy = (i ~/ newColumns) * cell;
    for (var y = 0; y < cell; y++) {
      for (var x = 0; x < cell; x++) {
        final pixel = atlas.getPixel(sx + x, sy + y);
        packed.setPixelRgba(
          dx + x,
          dy + y,
          pixel.r.toInt(),
          pixel.g.toInt(),
          pixel.b.toInt(),
          pixel.a.toInt(),
        );
      }
    }
  }

  File('assets/colors/block_textures.png').writeAsBytesSync(img.encodePng(packed));
  File('assets/colors/block_textures.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'cell': cell,
      'columns': newColumns,
      'blocks': {for (var i = 0; i < ids.length; i++) ids[i]: i},
    }),
  );
  File('assets/colors/kept_blocks.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(ids),
  );

  final removed = oldBlocks.keys.where((id) => !kept.contains(id)).length;
  stdout.writeln(
    'kept ${ids.length}, removed $removed from the atlas, '
    'unknown names ${unknown.length}',
  );
  if (unknown.isNotEmpty) {
    stdout.writeln(unknown.take(20).join(', '));
  }
}
