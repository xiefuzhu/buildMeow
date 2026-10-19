// Mirrors what the app builds, so "why is this block still in the palette" can
// be answered from data instead of from the UI.
//
// Usage, from the mapart_core package root:
//   dart run tool/palette_probe.dart [name filter]
import 'dart:convert';
import 'dart:io';

import 'package:mapart_core/mapart_core.dart';

void main(List<String> args) {
  final filter = args.isEmpty ? '' : args.first.toLowerCase();
  final kept = (jsonDecode(
            File('assets/colors/kept_blocks.json').readAsStringSync(),
          )
          as List<Object?>)
      .cast<String>()
      .toSet();

  final table = ColorTable.fromJson(
    jsonDecode(File('assets/colors/mapartcraft.colors.json').readAsStringSync())
        as Map<String, dynamic>,
  ).includingGameBlocks(
    jsonDecode(File('assets/colors/block_map_colors.json').readAsStringSync())
        as Map<String, dynamic>,
    '26.1.2',
  );
  final colors = _blockColors(kept);
  final palette = Palette.blocks(
    table,
    '1.20',
    gameVersion: '26.1.2',
    includeSupportBlocks: true,
  ).withBlockColors(colors, host: table.colors.first);

  stdout.writeln('kept_blocks.json: ${kept.length} ids');
  stdout.writeln('block colours after the filter: ${colors.length} ids');
  stdout.writeln('app palette: ${palette.length} entries, '
      '${palette.distinctColorCount} distinct colours');

  // Which palette entries are not backed by a kept texture. These are the ones
  // that only survive because they come from the shared map-colour list.
  final untracked = palette.entries
      .where((e) => !colors.containsKey(e.blockId))
      .map((e) => e.blockId)
      .toSet();
  stdout.writeln('entries with no kept texture: ${untracked.length}');
  if (untracked.isNotEmpty) {
    final sample = untracked.toList()..sort();
    stdout.writeln('  ${sample.take(20).join(', ')}');
  }

  if (filter.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('palette entries matching "$filter":');
    for (final entry in palette.entries) {
      if (entry.blockId.contains(filter) || entry.name.toLowerCase().contains(filter)) {
        stdout.writeln(
          '  ${entry.blockId.padRight(30)}${entry.name.padRight(20)}'
          'kept texture: ${colors.containsKey(entry.blockId)}',
        );
      }
    }
  }
}

Map<String, int> _blockColors(Set<String> kept) {
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
  final fallback = <String, int>{};
  final preferred = <String, int>{};
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
    if (kept.isNotEmpty && !kept.contains(id)) continue;
    final packed =
        ((srgb[0] as num).toInt() << 16) |
        ((srgb[1] as num).toInt() << 8) |
        (srgb[2] as num).toInt();
    if (block['excluded'] == null) {
      preferred[id] = packed;
    } else {
      fallback.putIfAbsent(id, () => packed);
    }
  }
  return {...fallback, ...preferred};
}
