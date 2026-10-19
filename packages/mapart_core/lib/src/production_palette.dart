import 'art_kind.dart';
import 'block_state_ref.dart';
import 'color_table.dart';
import 'palette.dart';
import 'version_table.dart';

/// Physical exclusions are generated from the game and texture catalogues.
/// Missing evidence is deliberately not treated as a promise of buildability.
class BlockCapabilities {
  const BlockCapabilities(
    this.mapReasons,
    this.textureReasons, [
    this.textureStates = const {},
    this.knownBlocks,
  ]);
  final Map<String, String> mapReasons;
  final Map<String, String> textureReasons;
  final Map<String, String> textureStates;
  final Set<String>? knownBlocks;
  factory BlockCapabilities.fromJson(Map<String, dynamic> json) {
    Map<String, String> read(String key) => (json[key] as Map<String, dynamic>)
        .map((id, reason) => MapEntry(id, reason as String));
    return BlockCapabilities(
      read('mapReasons'),
      read('textureReasons'),
      json.containsKey('textureStates') ? read('textureStates') : const {},
      json['knownBlocks'] is List
          ? (json['knownBlocks'] as List<dynamic>).cast<String>().toSet()
          : null,
    );
  }
  Map<String, String> reasonsFor(ArtKind kind) =>
      kind == ArtKind.mapItem ? mapReasons : textureReasons;
}

Palette resolveProductionPalette({
  required ColorTable table,
  required MinecraftVersion version,
  required ArtKind kind,
  bool flatMap = false,
  Map<String, int> blockColors = const {},
  BlockCapabilities? capabilities,
}) {
  final base = Palette.blocks(
    table,
    version.blockSetAlias,
    gameVersion: version.id,
    includeSupportBlocks: true,
  );
  if (kind == ArtKind.blockPixels && blockColors.isEmpty) {
    return base.onlyKeys(const {});
  }
  final palette = kind == ArtKind.blockPixels
      ? base
            .withBlockColors(blockColors, host: table.colors.first)
            .withBlockStates({
              for (final entry
                  in (capabilities?.textureStates ?? const <String, String>{})
                      .entries)
                entry.key: BlockStateRef.parse(entry.value),
            })
            .uniqueStates()
      : base;
  final reasons = capabilities?.reasonsFor(kind) ?? const <String, String>{};
  final forbidden = <String>{};
  for (final entry in palette.entries) {
    if (entry.needsSupport ||
        (capabilities?.knownBlocks != null &&
            !capabilities!.knownBlocks!.contains(entry.blockId)) ||
        entry.blockId == 'water' ||
        entry.blockId == 'lava' ||
        reasons.containsKey(entry.blockId)) {
      forbidden.add(entry.key);
    }
  }
  final available = palette.excludingKeys(forbidden);
  return kind == ArtKind.mapItem && flatMap
      ? available.atNormalMapShade()
      : available;
}
