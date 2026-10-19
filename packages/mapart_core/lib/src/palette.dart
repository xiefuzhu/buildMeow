import 'package:meta/meta.dart';

import 'block_state_ref.dart';
import 'color_table.dart';
import 'rgb.dart';
import 'shade_tier.dart';

/// One base colour paired with the block that will produce it.
@immutable
class PaletteEntry {
  const PaletteEntry({
    required this.color,
    required this.block,
    required this.state,
    Rgb? appearance,
  }) : _appearance = appearance;

  final MapBaseColor color;

  /// The chosen candidate, kept so the UI can show what it is (its name,
  /// whether it is flammable, whether it needs a support block).
  final MapBlockOption block;

  /// [block] resolved for the palette's target version.
  final BlockStateRef state;

  /// This block's own colour, from its texture. When set, the map stores this
  /// instead of the shared [MapBaseColor], so two blocks of one map colour
  /// (white wool, white concrete) are no longer the same swatch.
  final Rgb? _appearance;

  int get colorIndex => color.index;

  /// The base colour's name, e.g. `Grass`, `White Wool`, `Crimson Nylium`.
  ///
  /// Shared by every entry of that colour, so it is not enough to tell two
  /// entries apart — use [blockName] for that.
  String get name => color.name;

  /// The block's English name, e.g. `White Concrete`. This is what the
  /// blueprint and the material list name.
  String get blockName => block.displayName;

  /// Stable identity of this (base colour, block) pair.
  ///
  /// `presetIndex` is only unique *within* a colour — upstream numbers presets
  /// per colour, so every colour has a preset 0 — which is why the colour index
  /// has to be part of the key. Used by the UI to remember which blocks the
  /// user switched off, so it must not change when the table is reloaded.
  String get key => '$colorIndex:${block.presetIndex}';

  /// The colour this entry shows. A block with its own [appearance] keeps that
  /// colour at every shade, because the stored colour is the block's, not a
  /// darkened copy of a shared map colour.
  Rgb tone(ShadeTier tier) => _appearance ?? color.tone(tier);

  /// Whether [tone] ignores the shade. True for a texture average: raising the
  /// block does not make the block itself brighter, so the three staircase
  /// shades are the same candidate.
  bool get ignoresShade => _appearance != null;

  /// Block id without a namespace, e.g. `oak_planks`.
  String get blockId => state.namespacedId.split(':').last;

  /// Whether the block can catch fire. Upstream carries the flag but does not
  /// use it; it is worth surfacing because a flammable build is a hazard.
  bool get flammable => block.flammable;

  /// Whether the block needs something underneath it to exist — a slab, a
  /// carpet, sand, a cobweb.
  ///
  /// Staircase mapart is built out of full solid cubes, so entries with this
  /// set are off by default. The flag is upstream's and is not perfectly
  /// consistent (it is set on `slime_block` and `gravel`, which are both full
  /// cubes, and clear on `mud_brick_slab`), so it is a filter to be offered
  /// rather than trusted.
  bool get needsSupport => block.supportBlockMandatory;

  /// How many candidate blocks upstream lists for this colour, across all
  /// versions and including the support-requiring ones.
  int get alternativeCount => color.blocks.length;

  @override
  String toString() =>
      'PaletteEntry(${color.index}, $name / $blockName '
      '-> $state)';
}

/// The blocks staircase mapart may build with.
///
/// Two shapes of palette come out of this class:
///
/// * [Palette.select] — one representative block per base colour, the shape the
///   quantizer and the height solver were originally tuned against.
/// * [Palette.blocks] — every candidate block of every colour, so the user can
///   choose what to build each colour out of instead of accepting one block per
///   colour. The representative comes first within each colour, which means a
///   palette with nothing switched off quantizes to exactly the same image as
///   [Palette.select] does.
@immutable
class Palette {
  const Palette._(this.entries, this.unavailableColorIndices, this.version);

  /// One entry per usable block, ordered by colour index and then by the
  /// preference described on [Palette.blocks].
  final List<PaletteEntry> entries;

  /// Colour indices with no usable candidate at [version]. With the
  /// support-requiring blocks left out this is just `Water` (index 10), whose
  /// only upstream entry is the fluid itself.
  final List<int> unavailableColorIndices;

  /// The Minecraft release this palette resolves block states for.
  final String version;

  int get length => entries.length;

  /// Every entry is a texture average, so shade does not change its colour.
  ///
  /// The matcher then searches once, at [ShadeTier.normal], and the height
  /// solver is left with no other legal step. A map-colour palette is not
  /// flat: there the shade is the colour, and the staircase is the point.
  bool get ignoresShade =>
      entries.isNotEmpty && entries.every((entry) => entry.ignoresShade);

  /// How many distinct colours the entries actually show, at full brightness.
  ///
  /// Without per-block colours this is the map-colour count. With them it is
  /// one per block whose texture has its own average, which is the number the
  /// matcher can land on.
  int get distinctColorCount {
    final seen = <int>{};
    for (final entry in entries) {
      final tone = entry.tone(ShadeTier.bright);
      seen.add((tone.r << 16) | (tone.g << 8) | tone.b);
    }
    return seen.length;
  }

  /// Stores [colors] on each block, keyed by block id (`oak_planks`).
  ///
  /// Packed as `0xRRGGBB`. Every id in [colors] becomes its own palette entry,
  /// so a block that the map-colour table never listed still counts as its own
  /// colour. Glass is dropped: it has no opaque face and must not be chosen.
  /// [host] is only used as a carrier for those extra entries; the colour the
  /// matcher sees is [colors], not the host.
  Palette withBlockColors(Map<String, int> colors, {MapBaseColor? host}) {
    if (colors.isEmpty) return this;
    final kept = <PaletteEntry>[];
    final seen = <String>{};
    for (final entry in entries) {
      if (_isGlass(entry.blockId)) continue;
      final packed = colors[entry.blockId];
      if (packed == null) continue;
      seen.add(entry.blockId);
      kept.add(
        PaletteEntry(
          color: entry.color,
          block: entry.block,
          state: entry.state,
          appearance: _unpack(packed),
        ),
      );
    }
    if (host != null) {
      var preset = 100000;
      for (final id in colors.keys) {
        if (_isGlass(id) || !seen.add(id)) continue;
        final appearance = _unpack(colors[id]!);
        kept.add(
          PaletteEntry(
            color: host,
            block: MapBlockOption(
              blockId: preset,
              displayName: _titleFromId(id),
              statesByVersion: {version: BlockStateRef(id)},
              supportBlockMandatory: false,
              flammable: false,
              presetIndex: preset,
            ),
            state: BlockStateRef(id),
            appearance: appearance,
          ),
        );
        preset++;
      }
    }
    return Palette._(List.unmodifiable(kept), unavailableColorIndices, version);
  }

  /// Match only the map colour produced by a level surface. Keeping identical
  /// tones makes quantization pin every cell to the normal tier, including FS.
  Palette atNormalMapShade() => Palette._(
    List.unmodifiable([
      for (final entry in entries)
        PaletteEntry(
          color: entry.color,
          block: entry.block,
          state: entry.state,
          appearance: entry.tone(ShadeTier.normal),
        ),
    ]),
    unavailableColorIndices,
    version,
  );

  /// Keep the block state that actually produced the selected face texture.
  Palette withBlockStates(Map<String, BlockStateRef> states) => Palette._(
    List.unmodifiable([
      for (final entry in entries)
        PaletteEntry(
          color: entry.color,
          block: entry.block,
          state: states[entry.blockId] ?? entry.state,
          appearance: entry._appearance,
        ),
    ]),
    unavailableColorIndices,
    version,
  );

  /// Texture mode can collapse several map-facing variants into one state.
  /// Expose that physical candidate once, so disabling it really excludes it.
  Palette uniqueStates() {
    final seen = <String>{};
    return Palette._(
      List.unmodifiable(
        entries.where((entry) => seen.add(entry.state.toBlockStateString())),
      ),
      unavailableColorIndices,
      version,
    );
  }

  static bool _isGlass(String id) => id.contains('glass') || id == 'beacon';

  static String _titleFromId(String id) => id
      .split('_')
      .map(
        (word) => word.isEmpty
            ? word
            : '${word[0].toUpperCase()}${word.substring(1)}',
      )
      .join(' ');

  static Rgb _unpack(int packed) =>
      Rgb((packed >> 16) & 0xff, (packed >> 8) & 0xff, packed & 0xff);
  int get colorCount {
    final seen = <int>{};
    for (final entry in entries) {
      seen.add(entry.colorIndex);
    }
    return seen.length;
  }

  /// Every base colour index present in [entries], ascending.
  List<int> get colorIndices {
    final seen = <int>{};
    for (final entry in entries) {
      seen.add(entry.colorIndex);
    }
    final out = seen.toList()..sort();
    return List.unmodifiable(out);
  }

  /// Picks a representative block per base colour.
  ///
  /// The rules, in order:
  ///
  /// 1. Only blocks with `supportBlockMandatory == false`, which excludes
  ///    slabs, pressure plates, carpets, sand and other blocks that need
  ///    something underneath them. This satisfies "full solid cubes only".
  /// 2. Prefer blocks that are not flammable. Where every candidate is
  ///    flammable (leaves, for instance) the flammable one is used anyway,
  ///    since the alternative would be losing that colour.
  /// 3. Among the survivors, the lowest `presetIndex` wins. Upstream orders
  ///    presets roughly by how typical a choice the block is.
  ///
  /// Colours with no candidate at all are reported in
  /// [unavailableColorIndices] rather than guessed at.
  factory Palette.select(ColorTable table, String version) {
    final entries = <PaletteEntry>[];
    final unavailable = <int>[];

    for (final color in table.colors) {
      final candidates = _candidates(color, version, false);
      if (candidates.isEmpty) {
        unavailable.add(color.index);
        continue;
      }
      entries.add(_entry(color, _preferred(candidates), version));
    }

    return Palette._(
      List.unmodifiable(entries),
      List.unmodifiable(unavailable),
      version,
    );
  }

  /// Every candidate block of every usable colour, one entry each.
  ///
  /// This is the palette the app shows: the map only has 61 base colours and
  /// staircase mapart can only reach three shades of each, but *which block*
  /// produces a colour is free. Upstream lists 324 candidates across the 61
  /// colours, of which 209 are full solid cubes, and every one of them is a
  /// legitimate choice — white wool, white concrete, quartz and iron blocks all
  /// render the same on a map but cost different materials and one of them may
  /// burn.
  ///
  /// Within each colour the entry [Palette.select] would have picked is listed
  /// first. `quantize` breaks an exact tie on the lowest entry index, so a
  /// palette with nothing switched off reproduces the one-block-per-colour
  /// result exactly; switching the first block off is what hands the colour to
  /// the next one.
  ///
  /// [includeSupportBlocks] also admits the blocks that need something
  /// underneath them. They are off by default because a staircase is built from
  /// full cubes, but they are the difference between 209 and 324 choices, so the
  /// UI offers them rather than dropping them — and enabling them also brings
  /// colour 10 (`Water`) into reach.
  factory Palette.blocks(
    ColorTable table,
    String version, {
    String? gameVersion,
    bool includeSupportBlocks = false,
  }) {
    final entries = <PaletteEntry>[];
    final unavailable = <int>[];

    for (final color in table.colors) {
      final candidates = _candidates(
        color,
        version,
        includeSupportBlocks,
        gameVersion,
      );
      if (candidates.isEmpty) {
        unavailable.add(color.index);
        continue;
      }
      final preferred = _preferred(candidates);
      entries.add(_entry(color, preferred, version, gameVersion));
      for (final block in candidates) {
        if (identical(block, preferred)) continue;
        entries.add(_entry(color, block, version, gameVersion));
      }
    }

    return Palette._(
      List.unmodifiable(entries),
      List.unmodifiable(unavailable),
      version,
    );
  }

  /// Candidates for [color] at [version], lowest `presetIndex` first.
  ///
  /// Sorted rather than left in upstream's order so that the representative —
  /// and therefore the block the quantizer settles on — is a property of
  /// `presetIndex` alone and does not move if upstream reorders its JSON.
  /// [gameVersion] is the release the user is actually building for, which can
  /// differ from [version]: the vendored table stops at `1.20`, so a 1.21.4
  /// build resolves old blocks through that alias and blocks added later
  /// through their own release id.
  static List<MapBlockOption> _candidates(
    MapBaseColor color,
    String version,
    bool includeSupportBlocks, [
    String? gameVersion,
  ]) {
    final out = color.blocks
        .where(
          (b) =>
              (includeSupportBlocks || !b.supportBlockMandatory) &&
              _definedFor(b, version, gameVersion),
        )
        .toList();
    out.sort((a, b) => a.presetIndex.compareTo(b.presetIndex));
    return out;
  }

  static bool _definedFor(
    MapBlockOption block,
    String version,
    String? gameVersion,
  ) =>
      block.statesByVersion.containsKey(version) ||
      (gameVersion != null && block.statesByVersion.containsKey(gameVersion));

  /// Upstream's "most typical" block: non-flammable if possible, then the
  /// lowest `presetIndex`. [candidates] must be non-empty and sorted.
  static MapBlockOption _preferred(List<MapBlockOption> candidates) {
    for (final block in candidates) {
      if (!block.flammable) return block;
    }
    return candidates.first;
  }

  static PaletteEntry _entry(
    MapBaseColor color,
    MapBlockOption block,
    String version, [
    String? gameVersion,
  ]) => PaletteEntry(
    color: color,
    block: block,
    state: block.stateFor(gameVersion ?? version) ?? block.stateFor(version)!,
  );

  PaletteEntry? forColor(int colorIndex) {
    for (final entry in entries) {
      if (entry.colorIndex == colorIndex) return entry;
    }
    return null;
  }

  /// Every entry of one base colour, in palette order.
  List<PaletteEntry> entriesForColor(int colorIndex) =>
      entries.where((e) => e.colorIndex == colorIndex).toList(growable: false);

  /// Looks up an entry by its [PaletteEntry.key].
  PaletteEntry? entryFor(String key) {
    for (final entry in entries) {
      if (entry.key == key) return entry;
    }
    return null;
  }

  /// A palette with some colours switched off, as the one-block-per-colour UI
  /// does. Unavailable colours are carried over unchanged.
  Palette excluding(Set<int> colorIndices) {
    if (colorIndices.isEmpty) return this;
    return Palette._(
      List.unmodifiable(
        entries.where((e) => !colorIndices.contains(e.colorIndex)),
      ),
      unavailableColorIndices,
      version,
    );
  }

  /// A palette with only [colorIndices] switched on.
  Palette only(Set<int> colorIndices) => Palette._(
    List.unmodifiable(
      entries.where((e) => colorIndices.contains(e.colorIndex)),
    ),
    unavailableColorIndices,
    version,
  );

  /// A palette with individual blocks switched off, identified by
  /// [PaletteEntry.key].
  ///
  /// This is the per-block counterpart of [excluding], and what the app uses:
  /// turning off one of a colour's blocks hands that colour to the next block
  /// still enabled, and turning off the last one drops the colour.
  Palette excludingKeys(Set<String> keys) {
    if (keys.isEmpty) return this;
    return Palette._(
      List.unmodifiable(entries.where((e) => !keys.contains(e.key))),
      unavailableColorIndices,
      version,
    );
  }

  /// A palette with only the blocks named by [keys] switched on.
  Palette onlyKeys(Set<String> keys) => Palette._(
    List.unmodifiable(entries.where((e) => keys.contains(e.key))),
    unavailableColorIndices,
    version,
  );

  /// A palette with only the entries at [indices] kept.
  ///
  /// Used by the "at most N blocks" pass, which counts how many pixels each
  /// entry served and then re-matches against the winners. Indices are into
  /// [entries], so this cannot drift from what the first pass used.
  Palette onlyIndices(Set<int> indices) => Palette._(
    List.unmodifiable(<PaletteEntry>[
      for (var i = 0; i < entries.length; i++)
        if (indices.contains(i)) entries[i],
    ]),
    unavailableColorIndices,
    version,
  );
}
