import 'dart:convert';

import 'package:meta/meta.dart';

import '../block_state_ref.dart';
import '../json_util.dart';
import '../rgb.dart';
import 'block_face.dart';
import 'texture_palette.dart';

/// Reads and writes the extracted palette.
///
/// This is both the format the spec asks the tool to emit and the on-disk cache
/// the app keeps between runs: extraction reads a 30 MB jar and takes over a
/// second, so it happens once per jar and every later run reads this instead.
///
/// The version is in the payload so a change to the extraction can invalidate
/// caches rather than silently serving a palette built by older rules.
const int kTexturePaletteFormatVersion = 1;

Map<String, dynamic> texturePaletteToJson(TexturePalette palette) => {
  'formatVersion': kTexturePaletteFormatVersion,
  'source': palette.source,
  'face': palette.face.key,
  'elapsedMs': palette.elapsed.inMilliseconds,
  'blocks': [
    for (final entry in palette.entries)
      {
        'block': entry.blockId,
        'state': entry.state.toBlockStateString(),
        'face': entry.face.key,
        'texture': entry.texture,
        'excluded': entry.excluded?.name,
        if (entry.average != null) ...{
          'srgb': <int>[
            entry.average!.srgb.r,
            entry.average!.srgb.g,
            entry.average!.srgb.b,
          ],
          'linear': entry.average!.linear.toJson(),
          'noisiness': double.parse(
            entry.average!.noisiness.toStringAsFixed(3),
          ),
          'opaquePixels': entry.average!.opaquePixels,
        },
      },
  ],
};

/// Reads back what [texturePaletteToJson] wrote.
///
/// Throws [FormatException] on a payload from a different format version, which
/// the caller should treat as a cache miss rather than an error.
TexturePalette texturePaletteFromJson(Map<String, dynamic> json) {
  final version = asInt(json['formatVersion']);
  if (version != kTexturePaletteFormatVersion) {
    throw FormatException(
      'texture palette format version $version, expected '
      '$kTexturePaletteFormatVersion',
    );
  }

  final face = BlockFace.byKey(asString(json['face']));
  if (face == null) {
    throw FormatException('unknown face "${json['face']}"');
  }

  final entries = <TexturePaletteEntry>[];
  for (final raw in asList(json['blocks'])) {
    final block = asMap(raw);
    final rawExcluded = block['excluded'];
    final srgb = block['srgb'];

    AverageColor? average;
    if (srgb != null) {
      final channels = asList(srgb).map(asInt).toList(growable: false);
      final linear = asList(
        block['linear'],
      ).map((v) => (v! as num).toDouble()).toList(growable: false);
      average = AverageColor(
        srgb: Rgb(channels[0], channels[1], channels[2]),
        linear: LinearRgb(linear[0], linear[1], linear[2]),
        noisiness: (block['noisiness']! as num).toDouble(),
        opaquePixels: asInt(block['opaquePixels']),
      );
    }

    entries.add(
      TexturePaletteEntry(
        blockId: asString(block['block']),
        state: _stateFromString(asString(block['state'])),
        texture: asString(block['texture']),
        face: BlockFace.byKey(asString(block['face'])) ?? face,
        average: average,
        excluded: rawExcluded == null
            ? null
            : ExclusionReason.values.firstWhere(
                (r) => r.name == rawExcluded,
                orElse: () => throw FormatException(
                  'unknown exclusion reason "$rawExcluded"',
                ),
              ),
      ),
    );
  }

  return TexturePalette(
    entries: List.unmodifiable(entries),
    source: asString(json['source']),
    face: face,
    elapsed: Duration(milliseconds: asInt(json['elapsedMs'])),
  );
}

/// Parses `minecraft:oak_log[axis=y]` back into a state reference.
BlockStateRef _stateFromString(String value) {
  final open = value.indexOf('[');
  if (open < 0 || !value.endsWith(']')) return BlockStateRef(value);
  final properties = <String, String>{};
  for (final part in value.substring(open + 1, value.length - 1).split(',')) {
    final eq = part.indexOf('=');
    if (eq <= 0) continue;
    properties[part.substring(0, eq)] = part.substring(eq + 1);
  }
  return BlockStateRef(value.substring(0, open), properties);
}

/// The JSON text, indented so the file is readable when someone opens it.
String encodeTexturePalette(TexturePalette palette) =>
    const JsonEncoder.withIndent('  ').convert(texturePaletteToJson(palette));

/// A convenience for callers that only want the selected blocks in the file.
@immutable
class TexturePaletteDocument {
  const TexturePaletteDocument({
    required this.palette,
    required this.selected,
    required this.options,
  });

  final TexturePalette palette;
  final List<PaletteBlock> selected;
  final TexturePaletteOptions options;

  Map<String, dynamic> toJson() {
    final selectedKeys = {for (final block in selected) block.key};
    return {
      ...texturePaletteToJson(palette),
      'options': {
        'applyFaceBrightness': options.applyFaceBrightness,
        'maxNoisiness': options.maxNoisiness,
        'dedupeDistance': options.dedupeDistance,
        'includeFalling': options.includeFalling,
        'includeEmissive': options.includeEmissive,
        'includePatterned': options.includePatterned,
      },
      'selected': [
        for (final block in selected)
          {
            'key': block.key,
            'block': block.blockId,
            'srgb': <int>[block.color.r, block.color.g, block.color.b],
            'linear': block.linear.toJson(),
            'noisiness': double.parse(block.noisiness.toStringAsFixed(3)),
          },
      ],
      'selectedCount': selected.length,
      // Every block in the palette is in `blocks` above with its reason; this
      // is just the list of which ones the thresholds kept.
      'usableCount': selectedKeys.length,
    };
  }

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}
