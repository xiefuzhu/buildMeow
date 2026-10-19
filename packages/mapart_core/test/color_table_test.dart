import 'package:mapart_core/mapart_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late ColorTable table;

  setUpAll(() {
    table = loadColorTable();
  });

  group('table shape', () {
    test('carries 61 base colours indexed 0..60 in order', () {
      expect(table.length, 61);
      for (var i = 0; i < table.length; i++) {
        expect(table[i].index, i, reason: 'colours must be in index order');
      }
    });

    test('every colour has all four shade tones', () {
      for (final color in table.colors) {
        for (final tier in ShadeTier.values) {
          expect(
            color.tones.containsKey(tier),
            isTrue,
            reason: 'colour ${color.index} (${color.name}) is missing $tier',
          );
        }
      }
    });

    test('mapdatId is unique across colours', () {
      final ids = table.colors.map((c) => c.mapdatId).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('colour names are non-empty and unique', () {
      final names = table.colors.map((c) => c.name).toList();
      expect(names.where((n) => n.trim().isEmpty), isEmpty);
      expect(names.toSet().length, names.length);
    });
  });

  group('shade arithmetic', () {
    // This is the test that ties the vendored data to the rule staircase
    // mapart depends on: a map pixel is the base colour multiplied by
    // 255/255, 220/255, 180/255 or 135/255, floored.
    //
    // If this ever fails, the colour table and the height solver disagree and
    // every preview would be wrong.
    test('every tone equals floor(base * factor)', () {
      final violations = <String>[];

      for (final color in table.colors) {
        final base = color.baseColor;
        for (final tier in ShadeTier.values) {
          final expected = tier == ShadeTier.bright
              ? base
              : base.scaledBy(tier.numerator, ShadeTier.denominator);
          final actual = color.tone(tier);
          if (actual != expected) {
            violations.add(
              'colour ${color.index} (${color.name}) $tier: '
              'stored $actual, base $base * ${tier.numerator}/255 = $expected',
            );
          }
        }
      }

      expect(violations, isEmpty, reason: violations.join('\n'));
    });

    test('shade multipliers are 1.0, 220/255, 180/255, 135/255', () {
      expect(ShadeTier.bright.multiplier, 1.0);
      expect(ShadeTier.normal.multiplier, closeTo(220 / 255, 1e-12));
      expect(ShadeTier.dark.multiplier, closeTo(180 / 255, 1e-12));
      expect(ShadeTier.water.multiplier, closeTo(135 / 255, 1e-12));
    });

    test('darker tiers are never brighter than lighter ones', () {
      for (final color in table.colors) {
        final base = color.baseColor;
        for (final tier in <ShadeTier>[
          ShadeTier.normal,
          ShadeTier.dark,
          ShadeTier.water,
        ]) {
          final tone = color.tone(tier);
          expect(
            tone.r <= base.r && tone.g <= base.g && tone.b <= base.b,
            isTrue,
            reason: 'colour ${color.index} ${color.name} $tier $tone is not '
                'darker than base $base',
          );
        }
      }
    });
  });

  group('block version resolution', () {
    test('grass_block resolves for 1.20 through a version reference', () {
      // Upstream stores 1.14.4..1.20 as the string "&1.13.2", so this also
      // covers following references.
      final grass = table[0].blocks.firstWhere(
        (b) => b.displayName == 'Grass Block',
      );
      expect(grass.displayName, 'Grass Block');
      expect(grass.stateFor('1.20')?.namespacedId, 'minecraft:grass_block');
      expect(grass.stateFor('1.20')?.properties, isEmpty);
      // 1.12.2 predates the flattening and uses a different id.
      expect(grass.stateFor('1.12.2')?.namespacedId, 'minecraft:grass');
    });

    test('block state properties survive resolution', () {
      final leaves = table[6].blocks.firstWhere(
        (b) => b.displayName == 'Leaves (Oak)',
      );
      final state = leaves.stateFor('1.20');
      expect(state?.namespacedId, 'minecraft:oak_leaves');
      expect(state?.properties, {'persistent': 'true'});
      expect(state?.toBlockStateString(), 'minecraft:oak_leaves[persistent=true]');
    });

    test('references resolve for every version upstream lists', () {
      for (final color in table.colors) {
        for (final block in color.blocks) {
          for (final version in block.statesByVersion.keys) {
            expect(
              block.stateFor(version),
              isNotNull,
              reason: '${color.name} / ${block.displayName} / $version',
            );
          }
        }
      }
    });

    test('no block resolves for a version upstream does not carry', () {
      // 1.21 is exactly the gap we work around with blockSetAlias.
      final grass = table[0].blocks.firstWhere(
        (b) => b.displayName == 'Grass Block',
      );
      expect(grass.stateFor('1.21'), isNull);
      expect(grass.stateFor('1.21.4'), isNull);
    });
  });

  group('block state string formatting', () {
    test('sorts properties by key, as the Sponge spec requires', () {
      const state = BlockStateRef('oak_log', {'variant': 'oak', 'axis': 'y'});
      expect(state.toBlockStateString(), 'minecraft:oak_log[axis=y,variant=oak]');
    });

    test('omits the bracket part when there are no properties', () {
      expect(
        const BlockStateRef('stone').toBlockStateString(),
        'minecraft:stone',
      );
    });

    test('keeps an explicit namespace', () {
      expect(
        const BlockStateRef('custom:thing').toBlockStateString(),
        'custom:thing',
      );
    });
  });
}
