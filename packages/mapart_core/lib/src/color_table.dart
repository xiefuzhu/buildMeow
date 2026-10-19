import 'package:meta/meta.dart';

import 'block_state_ref.dart';
import 'json_util.dart';
import 'rgb.dart';
import 'shade_tier.dart';

/// One candidate block that renders as a particular base map colour.
@immutable
class MapBlockOption {
  const MapBlockOption({
    required this.blockId,
    required this.displayName,
    required this.statesByVersion,
    required this.supportBlockMandatory,
    required this.flammable,
    required this.presetIndex,
  });

  /// Per-colour index of this block in the upstream table. Only used for
  /// diagnostics; `presetIndex` is the stable identifier.
  final int blockId;

  /// Human-readable English name, e.g. `Grass Block`.
  final String displayName;

  /// Concrete block state per Minecraft version, with upstream's `&version`
  /// references already followed. A version missing from this map has no
  /// definition upstream.
  final Map<String, BlockStateRef> statesByVersion;

  /// Whether the block necessarily needs a support block underneath it, e.g. a
  /// slab, a pressure plate, sand, or a cobweb.
  ///
  /// Staircase mapart only uses full solid cubes, so these are excluded from
  /// the automatic palette. The flag also happens to be a decent proxy for
  /// "not a full cube", though upstream is not perfectly consistent about it.
  final bool supportBlockMandatory;

  /// Whether the block can catch fire. Upstream marks this as currently unused
  /// by their own generator. Kept because a flammable build is worth warning
  /// about.
  final bool flammable;

  /// Stable id used by upstream's preset URLs.
  final int presetIndex;

  BlockStateRef? stateFor(String version) => statesByVersion[version];

  @override
  String toString() => '$displayName (${statesByVersion.length} versions)';
}

/// A base map colour and its four pre-computed shades.
@immutable
class MapBaseColor {
  const MapBaseColor({
    required this.index,
    required this.name,
    required this.mapdatId,
    required this.tones,
    required this.blocks,
  });

  /// Index into the table, `0`..`60`.
  final int index;

  /// Upstream's name, e.g. `Grass`, `White Wool`, `Crimson Nylium`.
  final String name;

  /// Id used in map `.dat` files.
  final int mapdatId;

  final Map<ShadeTier, Rgb> tones;

  final List<MapBlockOption> blocks;

  Rgb tone(ShadeTier tier) {
    final value = tones[tier];
    if (value == null) {
      throw StateError('base colour $index ($name) has no $tier tone');
    }
    return value;
  }

  /// The 255/255 tone, which is the base colour itself.
  Rgb get baseColor => tone(ShadeTier.bright);

  /// Blocks that staircase mapart may use at [version]: full solid cubes that
  /// do not demand a support block and that upstream defines for the version.
  List<MapBlockOption> usableBlocks(String version) => blocks
      .where(
        (b) =>
            !b.supportBlockMandatory && b.statesByVersion.containsKey(version),
      )
      .toList(growable: false);

  @override
  String toString() => 'MapBaseColor($index, $name)';
}

/// The vendored MapartCraft colour table: 61 base colours, each with four
/// shades and a list of candidate blocks.
@immutable
class ColorTable {
  const ColorTable._(this.colors);

  /// Base colours ordered by index.
  final List<MapBaseColor> colors;

  /// How many colours the table carries. One of these is not usable by
  /// staircase mapart as-is: `Water` has no full-solid-cube candidate at all.
  int get length => colors.length;

  MapBaseColor operator [](int index) => colors[index];

  /// Parses the vendored `mapartcraft.colors.json`.
  ///
  /// The root object maps `"0"`..`"60"` to colour entries. Keys are sorted
  /// numerically rather than relying on JSON object order.
  factory ColorTable.fromJson(Map<String, dynamic> json) {
    final entries = json.entries.toList()
      ..sort((a, b) => int.parse(a.key).compareTo(int.parse(b.key)));

    final colors = <MapBaseColor>[];
    for (final entry in entries) {
      final index = int.parse(entry.key);
      final raw = asMap(entry.value);

      final rawTones = asMap(raw['tonesRGB']);
      final tones = <ShadeTier, Rgb>{
        for (final tier in ShadeTier.values)
          tier: Rgb.fromJson(asList(rawTones[tier.upstreamKey])),
      };

      final rawBlocks = asMap(raw['blocks']);
      final blockEntries = rawBlocks.entries.toList()
        ..sort((a, b) => int.parse(a.key).compareTo(int.parse(b.key)));

      final blocks = <MapBlockOption>[];
      for (final blockEntry in blockEntries) {
        final block = asMap(blockEntry.value);
        blocks.add(
          MapBlockOption(
            blockId: int.parse(blockEntry.key),
            displayName: asString(block['displayName']),
            statesByVersion: _resolveStates(asMap(block['validVersions'])),
            supportBlockMandatory: asBool(block['supportBlockMandatory']),
            flammable: asBool(block['flammable']),
            presetIndex: asInt(block['presetIndex']),
          ),
        );
      }

      colors.add(
        MapBaseColor(
          index: index,
          name: asString(raw['colourName']),
          mapdatId: asInt(raw['mapdatId']),
          tones: tones,
          blocks: blocks,
        ),
      );
    }

    return ColorTable._(colors);
  }

  /// Resolves upstream's `validVersions` map into concrete block states.
  ///
  /// An entry is either `{NBTName, NBTArgs}` or a string `"&1.13.2"` meaning
  /// "identical to that version". References are followed transitively; a
  /// dangling or circular reference simply drops that version rather than
  /// throwing, because the caller can tell the difference via
  /// [MapBlockOption.statesByVersion].
  static Map<String, BlockStateRef> _resolveStates(Map<String, dynamic> raw) {
    final resolved = <String, BlockStateRef>{};

    BlockStateRef? resolve(String version, Set<String> seen) {
      final cached = resolved[version];
      if (cached != null) return cached;
      if (!raw.containsKey(version) || !seen.add(version)) return null;

      final entry = raw[version];
      if (entry is String) {
        if (!entry.startsWith('&')) {
          throw FormatException(
            'unexpected validVersions string "$entry" for $version',
          );
        }
        final target = resolve(entry.substring(1), seen);
        if (target != null) resolved[version] = target;
        return target;
      }

      final map = asMap(entry);
      final state = BlockStateRef(
        asString(map['NBTName']),
        asStringMap(map['NBTArgs']),
      );
      resolved[version] = state;
      return state;
    }

    final out = <String, BlockStateRef>{};
    for (final version in raw.keys) {
      final state = resolve(version, <String>{});
      if (state != null) out[version] = state;
    }
    return out;
  }

  /// Adds blocks the vendored table does not know about.
  ///
  /// [versions] is every release the app can target. A supplement block is
  /// registered for each of them that is at least as new as the block itself,
  /// so a 1.21.4 build can use pale oak and a 1.20 build cannot. Blocks are
  /// appended after the vendored ones, with a higher `presetIndex`, so the
  /// representative block of a colour — and therefore a generated picture —
  /// does not change until the user switches the earlier blocks off.
  ColorTable including(BlockSupplement supplement, Iterable<String> versions) {
    if (supplement.blocks.isEmpty) return this;
    final indexByRgb = <int, int>{};
    for (final color in colors) {
      final base = color.baseColor;
      indexByRgb[(base.r << 16) | (base.g << 8) | base.b] = color.index;
    }

    final extra = <int, List<MapBlockOption>>{};
    for (final block in supplement.blocks) {
      final index =
          indexByRgb[(block.rgb.r << 16) | (block.rgb.g << 8) | block.rgb.b];
      if (index == null) continue;
      final states = <String, BlockStateRef>{};
      for (final version in versions) {
        if (_versionRank(version) < _versionRank(block.since)) continue;
        states[version] = BlockStateRef(
          block.id,
          block.pillar ? const {'axis': 'y'} : const {},
        );
      }
      if (states.isEmpty) continue;
      final added = extra.putIfAbsent(index, () => <MapBlockOption>[]);
      final used = <int>{
        for (final existing in colors[index].blocks) existing.presetIndex,
        for (final existing in added) existing.presetIndex,
      };
      var preset = 0;
      while (used.contains(preset)) {
        preset++;
      }
      added.add(
        MapBlockOption(
          blockId: preset,
          displayName: block.displayName,
          statesByVersion: states,
          supportBlockMandatory: false,
          flammable: block.flammable,
          presetIndex: preset,
        ),
      );
    }
    if (extra.isEmpty) return this;

    return ColorTable._([
      for (final color in colors)
        if (extra[color.index] == null)
          color
        else
          MapBaseColor(
            index: color.index,
            name: color.name,
            mapdatId: color.mapdatId,
            tones: color.tones,
            blocks: [...color.blocks, ...extra[color.index]!],
          ),
    ]);
  }

  /// Adds the 26.1.2 block → map-colour catalogue.
  ///
  /// [catalog] is `block_map_colors.json`: every block whose colour the game
  /// registers, not a texture average. Blocks the vendored table already
  /// names are skipped. Full cubes join the normal palette; everything else
  /// is marked as needing support so it only appears when that switch is on.
  /// New entries are appended, so a colour's existing representative stays
  /// the default and a generated picture does not change.
  ColorTable includingGameBlocks(Map<String, dynamic> catalog, String version) {
    final listed = asMap(catalog['blocks']);
    final indexByRgb = <int, int>{};
    for (final color in colors) {
      final base = color.baseColor;
      indexByRgb[(base.r << 16) | (base.g << 8) | base.b] = color.index;
    }

    final known = <String>{};
    for (final color in colors) {
      for (final block in color.blocks) {
        for (final state in block.statesByVersion.values) {
          final id = state.namespacedId.split(':').last;
          known.add('$id|${state.properties['axis'] ?? ''}');
        }
      }
    }

    final extra = <int, List<MapBlockOption>>{};

    void add({
      required String id,
      required List<Object?> rgb,
      required bool flammable,
      required bool needsSupport,
      required String axis,
      required String displayName,
    }) {
      final identity = '$id|$axis';
      if (!known.add(identity)) return;
      if (rgb.length != 3) return;
      final packed =
          (asInt(rgb[0]) << 16) | (asInt(rgb[1]) << 8) | asInt(rgb[2]);
      final index = indexByRgb[packed];
      if (index == null) return;

      final added = extra.putIfAbsent(index, () => <MapBlockOption>[]);
      final used = <int>{
        for (final existing in colors[index].blocks) existing.presetIndex,
        for (final existing in added) existing.presetIndex,
      };
      var preset = 0;
      while (used.contains(preset)) {
        preset++;
      }
      added.add(
        MapBlockOption(
          blockId: preset,
          displayName: displayName,
          statesByVersion: {
            version: BlockStateRef(
              id,
              axis.isEmpty ? const {} : {'axis': axis},
            ),
          },
          supportBlockMandatory: needsSupport,
          flammable: flammable,
          presetIndex: preset,
        ),
      );
    }

    for (final entry in listed.entries) {
      if (entry.key.contains('glass') || entry.key == 'beacon') continue;
      final block = asMap(entry.value);
      if (asInt(block['mapColorId']) == 0) continue;
      final solid = asBool(block['staircaseCube']);
      final flammable = asBool(block['flammable']);
      final pillar = asBool(block['pillar']);
      final name = _titleCaseId(entry.key);
      add(
        id: entry.key,
        rgb: asList(block['rgb']),
        flammable: flammable,
        needsSupport: !solid,
        axis: pillar ? 'y' : '',
        displayName: name,
      );
      final side = block['sideRgb'];
      if (pillar && solid && side != null) {
        add(
          id: entry.key,
          rgb: asList(side),
          flammable: flammable,
          needsSupport: false,
          axis: 'x',
          displayName: '$name (side)',
        );
      }
    }

    if (extra.isEmpty) return this;
    return ColorTable._([
      for (final color in colors)
        if (extra[color.index] == null)
          color
        else
          MapBaseColor(
            index: color.index,
            name: color.name,
            mapdatId: color.mapdatId,
            tones: color.tones,
            blocks: [...color.blocks, ...extra[color.index]!],
          ),
    ]);
  }
}

/// Full-cube blocks read out of a Minecraft client and absent from the
/// vendored table. See `assets/colors/block_supplement.json`.
@immutable
class BlockSupplement {
  const BlockSupplement(this.blocks);

  static const empty = BlockSupplement(<SupplementBlock>[]);

  factory BlockSupplement.fromJson(Map<String, dynamic> json) {
    final raw = json['blocks'];
    if (raw is! List) {
      throw const FormatException('block supplement has no blocks list');
    }
    return BlockSupplement([
      for (final entry in raw) SupplementBlock.fromJson(asMap(entry)),
    ]);
  }

  final List<SupplementBlock> blocks;
}

/// One block from [BlockSupplement].
@immutable
class SupplementBlock {
  const SupplementBlock({
    required this.id,
    required this.displayName,
    required this.rgb,
    required this.flammable,
    required this.pillar,
    required this.since,
  });

  factory SupplementBlock.fromJson(Map<String, dynamic> json) =>
      SupplementBlock(
        id: asString(json['id']),
        displayName: asString(json['displayName']),
        rgb: Rgb.fromJson(asList(json['rgb'])),
        flammable: asBool(json['flammable']),
        pillar: asBool(json['pillar']),
        since: asString(json['since']),
      );

  final String id;
  final String displayName;
  final Rgb rgb;
  final bool flammable;
  final bool pillar;

  /// First Minecraft release this block exists in, e.g. `1.21.4`.
  final String since;
}

int _versionRank(String version) {
  final parts = version.split('.');
  var rank = 0;
  for (var i = 0; i < 3; i++) {
    final n = i < parts.length ? int.tryParse(parts[i]) ?? 0 : 0;
    rank = rank * 1000 + n;
  }
  return rank;
}

String _titleCaseId(String id) => id
    .split('_')
    .map(
      (word) =>
          word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}',
    )
    .join(' ');
