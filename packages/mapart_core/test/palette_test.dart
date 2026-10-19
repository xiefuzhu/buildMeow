import 'package:mapart_core/mapart_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Blocks that are not full solid cubes. A representative must never match one
/// of these. `supportBlockMandatory` is supposed to catch them, but upstream is
/// not perfectly consistent — `mud_brick_slab` is marked as *not* mandatory —
/// so this list is the backstop.
const _notAFullCube = <String>[
  '_slab',
  '_stairs',
  '_trapdoor',
  '_fence',
  '_fence_gate',
  '_wall',
  '_carpet',
  '_pressure_plate',
  '_button',
  '_door',
  '_pane',
  '_bars',
  '_rod',
  '_torch',
  '_lantern',
  '_chain',
  '_candle',
  '_sign',
  '_banner',
  '_bed',
  '_chest',
  '_shulker_box',
  '_anvil',
  '_cauldron',
  '_hopper',
  '_composter',
  '_grindstone',
  '_loom',
  '_stonecutter',
  '_bell',
  '_lever',
  '_repeater',
  '_comparator',
  '_rail',
  '_sapling',
  '_flower',
  '_vine',
  '_roots',
  '_sprouts',
  '_fungus',
  '_cluster',
  '_bud',
  '_coral',
  '_turtle_egg',
  '_scaffolding',
  '_ladder',
  '_piston',
  '_observer',
  '_dispenser',
  '_dropper',
];

/// The expected representative per base colour, resolved for the `1.20` block
/// set. Pinning the whole set means any upstream change or selection-rule
/// change has to be looked at deliberately.
const _expected = <int, String>{
  0: 'grass_block',
  1: 'sandstone',
  2: 'mushroom_stem',
  3: 'redstone_block',
  4: 'ice',
  5: 'iron_block',
  6: 'oak_leaves',
  7: 'clay',
  8: 'dirt',
  9: 'cobblestone',
  11: 'crafting_table',
  12: 'diorite',
  13: 'white_concrete',
  14: 'orange_concrete',
  15: 'magenta_concrete',
  16: 'light_blue_concrete',
  17: 'yellow_concrete',
  18: 'lime_concrete',
  19: 'pink_concrete',
  20: 'gray_concrete',
  21: 'light_gray_concrete',
  22: 'cyan_concrete',
  23: 'purple_concrete',
  24: 'blue_concrete',
  25: 'brown_concrete',
  26: 'green_concrete',
  27: 'red_concrete',
  28: 'black_concrete',
  29: 'gold_block',
  30: 'diamond_block',
  31: 'lapis_block',
  32: 'emerald_block',
  33: 'podzol',
  34: 'nether_bricks',
  35: 'white_terracotta',
  36: 'orange_terracotta',
  37: 'magenta_terracotta',
  38: 'light_blue_terracotta',
  39: 'yellow_terracotta',
  40: 'lime_terracotta',
  41: 'pink_terracotta',
  42: 'gray_terracotta',
  43: 'light_gray_terracotta',
  44: 'cyan_terracotta',
  45: 'purple_terracotta',
  46: 'blue_terracotta',
  47: 'brown_terracotta',
  48: 'green_terracotta',
  49: 'red_terracotta',
  50: 'black_terracotta',
  51: 'crimson_nylium',
  52: 'crimson_stem',
  53: 'crimson_hyphae',
  54: 'warped_nylium',
  55: 'warped_stem',
  56: 'warped_hyphae',
  57: 'warped_wart_block',
  58: 'deepslate',
  59: 'raw_iron_block',
  60: 'verdant_froglight',
};

void main() {
  late ColorTable table;
  late Palette palette;

  setUpAll(() {
    table = loadColorTable();
    palette = Palette.select(table, '1.20');
  });

  group('selection', () {
    test('every colour except Water gets a representative', () {
      expect(palette.unavailableColorIndices, <int>[10]);
      expect(palette.length, 60);
    });

    test('Water really has no full solid cube candidate', () {
      final water = table[10];
      expect(water.name, 'Water');
      expect(water.usableBlocks('1.20'), isEmpty);
      // Its only entry is the fluid itself, which needs a support block.
      expect(water.blocks, hasLength(1));
      expect(water.blocks.single.supportBlockMandatory, isTrue);
    });

    test('matches the pinned expectation exactly', () {
      final actual = <int, String>{
        for (final entry in palette.entries)
          entry.colorIndex: entry.state.name,
      };
      expect(actual, _expected);
    });

    test('no representative is a non-full-cube block', () {
      final offenders = <String>[];
      for (final entry in palette.entries) {
        final id = entry.state.namespacedId;
        for (final pattern in _notAFullCube) {
          if (id.contains(pattern)) offenders.add('$id matches "$pattern"');
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('no representative demands a support block', () {
      for (final entry in palette.entries) {
        expect(
          entry.block.supportBlockMandatory,
          isFalse,
          reason: '${entry.name} -> ${entry.state}',
        );
      }
    });

    test('block ids are unique across colours', () {
      final ids = palette.entries.map((e) => e.state.namespacedId).toList();
      final duplicates = <String>{};
      final seen = <String>{};
      for (final id in ids) {
        if (!seen.add(id)) duplicates.add(id);
      }
      expect(duplicates, isEmpty, reason: 'duplicated: $duplicates');
    });

    test('entry order follows colour index order', () {
      final indices = palette.entries.map((e) => e.colorIndex).toList();
      final sorted = [...indices]..sort();
      expect(indices, sorted);
    });

    test('a non-flammable candidate wins whenever one exists', () {
      // Leaves are the exception: every candidate for colour 6 is flammable.
      for (final entry in palette.entries) {
        final usable = entry.color.usableBlocks('1.20');
        final hasNonFlammable = usable.any((b) => !b.flammable);
        if (hasNonFlammable) {
          expect(
            entry.block.flammable,
            isFalse,
            reason: '${entry.name} picked flammable ${entry.state} even though '
                'a non-flammable candidate exists',
          );
        }
      }
    });

    test('selection is deterministic', () {
      final again = Palette.select(table, '1.20');
      expect(
        again.entries.map((e) => e.state.namespacedId).toList(),
        palette.entries.map((e) => e.state.namespacedId).toList(),
      );
    });

    test('selection is driven by presetIndex, the lowest winning', () {
      for (final entry in palette.entries) {
        final usable = entry.color.usableBlocks('1.20');
        final nonFlammable = usable.where((b) => !b.flammable);
        final pool = nonFlammable.isEmpty ? usable : nonFlammable;
        final lowest = pool
            .map((b) => b.presetIndex)
            .reduce((a, b) => a < b ? a : b);
        expect(entry.block.presetIndex, lowest, reason: entry.name);
      }
    });
  });

  group('per-version block states', () {
    test('block state properties are carried into the entry', () {
      final leaves = palette.forColor(6)!;
      expect(leaves.state.namespacedId, 'minecraft:oak_leaves');
      expect(
        leaves.state.toBlockStateString(),
        'minecraft:oak_leaves[persistent=true]',
      );
    });

    test('logs use their default state, which is axis=y', () {
      final stem = palette.forColor(52)!;
      expect(stem.state.namespacedId, 'minecraft:crimson_stem');
      expect(stem.state.properties, isEmpty);
    });

    test('the 1.12.2 block set uses pre-flattening ids', () {
      final old = Palette.select(table, '1.12.2');
      expect(old.forColor(0)!.state.namespacedId, 'minecraft:grass');
      expect(old.length, greaterThan(0));
    });
  });

  group('toggling colours off', () {
    test('excluding removes exactly those colours', () {
      final reduced = palette.excluding({0, 13});
      expect(reduced.length, palette.length - 2);
      expect(reduced.forColor(0), isNull);
      expect(reduced.forColor(13), isNull);
      expect(reduced.forColor(1), isNotNull);
      expect(reduced.unavailableColorIndices, <int>[10]);
    });

    test('excluding nothing returns the same palette', () {
      expect(identical(palette.excluding(<int>{}), palette), isTrue);
    });

    test('only keeps exactly the requested colours', () {
      final single = palette.only({13});
      expect(single.length, 1);
      expect(single.forColor(13)!.name, 'White Wool');
    });

    test('excluding a colour Water does not have is harmless', () {
      final reduced = palette.excluding({10});
      expect(reduced.length, palette.length);
    });
  });

  group('every block as a palette entry', () {
    test('lists one entry per full solid cube, across 60 colours', () {
      final all = Palette.blocks(table, '1.20');
      expect(all.length, 209);
      expect(all.colorCount, 60);
      expect(all.colorIndices, hasLength(60));
      expect(all.unavailableColorIndices, <int>[10]);
    });

    test('the representative is listed first for its colour', () {
      // This is what keeps the expanded palette from moving a single pixel:
      // `quantize` breaks an exact tie on the lowest entry index, and within a
      // colour the entry `select` would have chosen comes first.
      final all = Palette.blocks(table, '1.20');
      for (final expected in palette.entries) {
        final group = all.entriesForColor(expected.colorIndex);
        expect(group, isNotEmpty, reason: expected.name);
        expect(group.first.key, expected.key, reason: expected.name);
        expect(group.first.state, expected.state, reason: expected.name);
        expect(group.first.tone(ShadeTier.bright), expected.tone(ShadeTier.bright));
      }
    });

    test('keys are unique across the whole palette', () {
      final all = Palette.blocks(table, '1.20');
      expect(all.entries.map((e) => e.key).toSet(), hasLength(all.length));
    });

    test('presetIndex alone would not be unique, so the key carries the colour', () {
      final all = Palette.blocks(table, '1.20');
      // Every colour has its own preset 0, which is exactly why `key` cannot be
      // just the preset index.
      final presetZero = all.entries.where((e) => e.block.presetIndex == 0);
      expect(presetZero.length, greaterThan(1));
      expect(presetZero.map((e) => e.key).toSet(), hasLength(presetZero.length));
    });

    test('every entry resolves a block state for the target version', () {
      for (final entry in Palette.blocks(table, '1.20').entries) {
        expect(entry.state.namespacedId, startsWith('minecraft:'));
        expect(entry.block.statesByVersion, contains('1.20'));
      }
    });

    test('colour name and block name are both exposed for the UI', () {
      final group = Palette.blocks(table, '1.20').entriesForColor(13);
      expect(group.length, greaterThan(1));
      // One colour, several blocks: that is the point of the expanded palette,
      // and why the UI groups by colour rather than listing blocks flat.
      expect(group.map((e) => e.name).toSet(), {'White Wool'});
      expect(group.map((e) => e.blockName).toSet().length, group.length);
      expect(group.first.blockName, isNotEmpty);
    });

    test('the support-requiring blocks are available on request', () {
      final withSupport = Palette.blocks(
        table,
        '1.20',
        includeSupportBlocks: true,
      );
      expect(withSupport.length, 323);
      // Water's only entry is the fluid, which upstream itself marks
      // unsupported, so admitting them is also what brings colour 10 into
      // reach.
      expect(withSupport.unavailableColorIndices, isEmpty);
      expect(withSupport.colorCount, 61);
      final water = withSupport.entriesForColor(10);
      expect(water, hasLength(1));
      expect(water.single.needsSupport, isTrue);
    });

    test('the support-requiring blocks are left out by default', () {
      final all = Palette.blocks(table, '1.20');
      expect(all.entries.where((e) => e.needsSupport), isEmpty);
      // A handful of them are full cubes upstream mislabels, so the flag is
      // offered as a filter rather than trusted as a shape test.
      expect(
        all.entries.any((e) => e.block.supportBlockMandatory),
        isFalse,
      );
    });

    test('flammability is carried through to the entry', () {
      final all = Palette.blocks(table, '1.20');
      final wool = all
          .entriesForColor(13)
          .where((e) => e.blockName == 'White Wool')
          .toList();
      expect(wool, hasLength(1));
      expect(wool.single.flammable, isTrue);
      expect(all.entries.any((e) => !e.flammable), isTrue);
    });

    test('a per-version block set still applies', () {
      final old = Palette.blocks(table, '1.12.2');
      expect(old.length, 138);
      expect(old.entriesForColor(0).first.state.namespacedId, 'minecraft:grass');
    });

    test('entries stay ordered by colour so the UI can group them', () {
      final indices = Palette.blocks(
        table,
        '1.20',
      ).entries.map((e) => e.colorIndex).toList();
      final sorted = [...indices]..sort();
      expect(indices, sorted);
    });

    test('entryFor finds an entry by its key', () {
      final all = Palette.blocks(table, '1.20');
      final entry = all.entries[7];
      expect(all.entryFor(entry.key)!.blockName, entry.blockName);
      expect(all.entryFor('999:999'), isNull);
    });
  });

  group('toggling individual blocks off', () {
    test('excludingKeys removes exactly those entries', () {
      final all = Palette.blocks(table, '1.20');
      final group = all.entriesForColor(13);
      expect(group.length, greaterThan(2));

      final reduced = all.excludingKeys({group.first.key, group.last.key});
      expect(reduced.length, all.length - 2);
      expect(reduced.entryFor(group.first.key), isNull);
      expect(reduced.entryFor(group.last.key), isNull);
      expect(reduced.entryFor(group[1].key), isNotNull);
      // The colour survives while any of its blocks is still on.
      expect(reduced.colorCount, all.colorCount);
    });

    test('the next block takes over when the first is switched off', () {
      final all = Palette.blocks(table, '1.20');
      final group = all.entriesForColor(13);
      final reduced = all.excludingKeys({group.first.key});
      expect(reduced.entriesForColor(13).first.key, group[1].key);
    });

    test('switching off every block of a colour drops the colour', () {
      final all = Palette.blocks(table, '1.20');
      final keys = all.entriesForColor(13).map((e) => e.key).toSet();
      final reduced = all.excludingKeys(keys);
      expect(reduced.forColor(13), isNull);
      expect(reduced.colorCount, all.colorCount - 1);
    });

    test('excluding nothing returns the same palette', () {
      final all = Palette.blocks(table, '1.20');
      expect(identical(all.excludingKeys(<String>{}), all), isTrue);
    });

    test('an unknown key is harmless', () {
      final all = Palette.blocks(table, '1.20');
      expect(all.excludingKeys({'999:999'}).length, all.length);
    });

    test('onlyKeys keeps exactly the named blocks', () {
      final all = Palette.blocks(table, '1.20');
      final group = all.entriesForColor(13);
      final kept = all.onlyKeys({group[1].key});
      expect(kept.length, 1);
      expect(kept.entries.single.blockName, group[1].blockName);
      expect(kept.colorCount, 1);
    });
  });

  test('a block stores its own colour, not the shared map colour', () {
    final palette = Palette.blocks(table, '1.20').withBlockColors(const {
      'white_wool': 0x112233,
      'white_concrete': 0x445566,
    });
    final wool = palette.entries.firstWhere((e) => e.blockId == 'white_wool');
    final concrete = palette.entries.firstWhere(
      (e) => e.blockId == 'white_concrete',
    );
    expect(wool.colorIndex, concrete.colorIndex);
    expect(wool.tone(ShadeTier.bright), const Rgb(0x11, 0x22, 0x33));
    expect(wool.tone(ShadeTier.dark), const Rgb(0x11, 0x22, 0x33));
    expect(concrete.tone(ShadeTier.normal), const Rgb(0x44, 0x55, 0x66));
    expect(palette.entries.any((e) => e.blockId == 'not_a_real_block'), isFalse);
    final expanded = Palette.blocks(
      table,
      '1.20',
      includeSupportBlocks: true,
    ).withBlockColors(
      const {'glass': 0xaabbcc, 'brand_new_block': 0x010203},
      host: table.colors.first,
    );
    expect(expanded.entries.where((e) => e.blockId.contains('glass')), isEmpty);
    final added = expanded.entries.where((e) => e.blockId == 'brand_new_block');
    expect(added, hasLength(1));
    expect(added.single.tone(ShadeTier.bright), const Rgb(1, 2, 3));
  });

  test('26.1.2 catalogue joins the palette', () {
    final merged = table.includingGameBlocks(loadBlockCatalog(), '26.1.2');
    final before = Palette.blocks(table, '1.20');
    final after = Palette.blocks(
      merged,
      '1.20',
      gameVersion: '26.1.2',
    );
    expect(after.length, greaterThan(before.length));
    expect(
      after.entries.map((e) => e.state.namespacedId),
      containsAll([
        'minecraft:pale_oak_planks',
        'minecraft:pale_oak_log',
        'minecraft:resin_block',
        'minecraft:creaking_heart',
      ]),
    );
    // A colour that already had a non-flammable block keeps it as the
    // default, so the generated picture's blocks do not move.
    for (final index in before.colorIndices) {
      final oldFirst = before.entriesForColor(index).first;
      if (oldFirst.flammable) continue;
      expect(
        after.entriesForColor(index).first.blockName,
        oldFirst.blockName,
        reason: oldFirst.name,
      );
    }
    final withSupport = Palette.blocks(
      merged,
      '1.20',
      gameVersion: '26.1.2',
      includeSupportBlocks: true,
    );
    expect(withSupport.length, greaterThan(after.length));
  });
}
