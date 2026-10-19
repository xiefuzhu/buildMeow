// Extracts a texture palette from a Minecraft jar and writes it as JSON.
//
// This is the same code path the app runs on a background isolate; it is here
// so the palette can be produced, eyeballed and diffed without the UI, and so
// the extraction cost can be measured on a real jar.
//
// Usage, from the mapart_core package root:
//   dart run tool/texture_palette_probe.dart [jar] [output.json] [face]
import 'dart:io';

import 'package:mapart_core/mapart_core.dart';

void main(List<String> args) {
  final jarPath = args.isNotEmpty
      ? args[0]
      : r'C:\Users\xiefuzhu\AppData\Roaming\.minecraft\versions\26.1.2\26.1.2.jar';
  final outPath = args.length > 1 ? args[1] : 'build/texture_palette.json';
  final face = args.length > 2 ? BlockFace.byKey(args[2]) : BlockFace.up;
  if (face == null) {
    stderr.writeln('unknown face "${args[2]}", expected one of '
        '${BlockFace.values.map((f) => f.key).join(', ')}');
    exitCode = 2;
    return;
  }

  final file = File(jarPath);
  if (!file.existsSync()) {
    stderr.writeln('no jar at $jarPath');
    exitCode = 1;
    return;
  }

  final bytes = file.readAsBytesSync();
  stdout.writeln('jar ${file.lengthSync()} bytes, reading ${face.key} faces');

  final watch = Stopwatch()..start();
  final palette = extractTexturePalette(
    bytes,
    source: jarPath,
    face: face,
  );
  watch.stop();

  final options = const TexturePaletteOptions();
  final selected = selectPaletteBlocks(palette, options);

  stdout.writeln('blockstates:        ${palette.entries.length}');
  stdout.writeln('reached a colour:   ${palette.accepted.length}');
  stdout.writeln('selected:           ${selected.length}');
  stdout.writeln('extract:            ${watch.elapsedMilliseconds} ms '
      '(extractor says ${palette.elapsed.inMilliseconds} ms)');
  stdout.writeln('');
  stdout.writeln('excluded:');
  final counts = palette.exclusionCounts;
  for (final reason in ExclusionReason.values) {
    final count = counts[reason];
    if (count == null) continue;
    stdout.writeln('   ${reason.name.padRight(14)} $count');
  }

  final darkest = [...selected]
    ..sort((a, b) => _luma(a).compareTo(_luma(b)));
  stdout.writeln('');
  stdout.writeln('darkest / lightest selected:');
  for (final block in <PaletteBlock>[
    ...darkest.take(3),
    ...darkest.reversed.take(3),
  ]) {
    stdout.writeln('   ${block.blockId.padRight(28)} ${block.color} '
        'noisy ${block.noisiness.toStringAsFixed(1)}');
  }

  final document = TexturePaletteDocument(
    palette: palette,
    selected: selected,
    options: options,
  );
  final out = File(outPath)..createSync(recursive: true);
  out.writeAsStringSync(document.encode());
  stdout.writeln('');
  stdout.writeln('wrote ${out.path} '
      '(${(out.lengthSync() / 1024).toStringAsFixed(0)} kB)');
}

double _luma(PaletteBlock block) =>
    0.2126 * block.color.r + 0.7152 * block.color.g + 0.0722 * block.color.b;
