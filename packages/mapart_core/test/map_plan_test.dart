import 'package:mapart_core/mapart_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The plan is the seam every later milestone reads: the material list, the
/// blueprint viewer, the PDF/PNG/CSV sheets and both schematic writers. These
/// tests pin the things that would silently make all of them wrong — the
/// mapping from pixels to blocks, the shade rule, and the fact that the plan
/// renders exactly what the solver rendered.
void main() {
  late Palette mapPalette;
  late Palette blockPalette;

  setUpAll(() {
    // The map-colour palette: the staircase case, where the shade is the
    // colour.
    mapPalette = Palette.select(loadColorTable(), '1.20');
    // The texture-average palette: the flat case, where raising a block does
    // not change it.
    blockPalette = loadAppPalette();
  });

  group('buildMapPlan', () {
    test('agrees with the renderer pixel for pixel', () {
      // If these two ever disagree the preview, the blueprint and the exported
      // schematics would each be showing something different, so this is the
      // invariant the whole milestone rests on.
      for (final palette in [mapPalette, blockPalette]) {
        final pipeline = Pipeline.run(
          gradient(128, 128),
          palette: palette,
          mapsX: 1,
          mapsY: 1,
        );
        final plan = pipeline.plan();
        final fromPlan = renderPlanMap(plan: plan);

        expect(
          fromPlan.bytes,
          pipeline.rendered.bytes,
          reason: 'plan and solver must produce the same map colours',
        );
      }
    });

    test('only lists blocks the picture actually uses', () {
      final pipeline = Pipeline.run(
        gradient(128, 128),
        palette: mapPalette,
        mapsX: 1,
        mapsY: 1,
      );
      final plan = pipeline.plan();

      expect(plan.blocks.length, lessThan(mapPalette.length));
      expect(plan.blocks, isNotEmpty);
      for (var i = 0; i < plan.blocks.length; i++) {
        expect(plan.counts[i], greaterThan(0), reason: plan.blocks[i].toString());
      }
      // Every pixel points at a listed block, and the counts add up to the
      // picture.
      var total = 0;
      for (var y = 0; y < plan.height; y++) {
        for (var x = 0; x < plan.width; x++) {
          final index = plan.blockIndexAt(x, y);
          expect(index, inInclusiveRange(0, plan.blocks.length - 1));
          total++;
        }
      }
      expect(plan.totalBlocks, total);
    });

    test('is sorted most-used first, and stably', () {
      final pipeline = Pipeline.run(
        noiseImage(128, 128),
        palette: mapPalette,
        mapsX: 1,
        mapsY: 1,
      );
      final plan = pipeline.plan();
      for (var i = 1; i < plan.counts.length; i++) {
        expect(plan.counts[i - 1], greaterThanOrEqualTo(plan.counts[i]));
      }
      // Same solve, same order: the material list must not shuffle between
      // runs.
      final again = pipeline.plan();
      expect(again.blocks.map((b) => b.key), plan.blocks.map((b) => b.key));
    });

    test('the shade of a pixel is the step to the block north of it', () {
      // The rule the whole project rests on, checked against the data rather
      // than against the solver's own bookkeeping.
      final pipeline = Pipeline.run(
        bands(128, 128),
        palette: mapPalette,
        mapsX: 1,
        mapsY: 1,
      );
      final plan = pipeline.plan();

      var stepped = 0;
      for (var y = 0; y < plan.height; y++) {
        for (var x = 0; x < plan.width; x++) {
          final relative = plan.relativeHeightAt(x, y);
          expect(relative, inInclusiveRange(-1, 1));
          final tier = plan.tierAt(x, y);
          expect(tier, ShadeTier.fromHeightDelta(relative));
          if (y == 0) {
            // Row 0 has no map pixel to the north, so it is compared against
            // the extra reference row.
            expect(
              plan.heightAt(x, 0) - plan.referenceRowHeight,
              relative,
            );
          }
          if (relative != 0) stepped++;
        }
      }
      // A banded picture must actually step somewhere, or the test proves
      // nothing about the staircase.
      expect(stepped, greaterThan(0));
    });

    test('the colour of a pixel is its block at its shade', () {
      final pipeline = Pipeline.run(
        gradient(128, 128),
        palette: mapPalette,
        mapsX: 1,
        mapsY: 1,
      );
      final plan = pipeline.plan();
      for (var y = 0; y < plan.height; y += 7) {
        for (var x = 0; x < plan.width; x += 11) {
          final block = plan.blockAt(x, y);
          expect(plan.colorAt(x, y), block.tone(plan.tierAt(x, y)));
        }
      }
    });

    test('a texture-average palette builds one flat layer', () {
      final pipeline = Pipeline.run(
        gradient(128, 128),
        palette: blockPalette,
        mapsX: 1,
        mapsY: 1,
      );
      final plan = pipeline.plan();

      expect(plan.blocks.every((b) => b.ignoresShade), isTrue);
      expect(plan.maxHeight - plan.minHeight, 0);
      for (var y = 0; y < plan.height; y++) {
        for (var x = 0; x < plan.width; x++) {
          expect(plan.tierAt(x, y), ShadeTier.normal);
        }
      }
    });

    test('carries the version the export has to write', () {
      final versions = loadVersionTable();
      final pipeline = Pipeline.run(
        gradient(128, 128),
        palette: mapPalette,
        mapsX: 2,
        mapsY: 1,
      );
      final plan = pipeline.plan();

      expect(plan.versionId, VersionTable.defaultVersionId);
      expect(plan.dataVersion, versions.require(plan.versionId).dataVersion);
      expect(plan.mapsX, 2);
      expect(plan.mapsY, 1);
      expect(plan.mapCount, 2);
    });

    test('labels blocks in Chinese, falling back to English', () {
      final pipeline = Pipeline.run(
        gradient(128, 128),
        palette: mapPalette,
        mapsX: 1,
        mapsY: 1,
      );
      final names = loadBlockNames();
      final plan = pipeline.plan(names: names);

      for (final block in plan.blocks) {
        expect(block.nameZh, isNotEmpty);
        expect(block.nameZh, names.zh(block.blockId) ?? block.nameEn);
        expect(block.blockState, startsWith('minecraft:'));
        expect(block.blockId, isNot(contains(':')));
      }
      // The Chinese names are not just the English ones copied over, or the
      // table would be pointless.
      expect(plan.blocks.first.nameZh, isNot(plan.blocks.first.nameEn));
    });

    test('a palette with no Chinese names still produces a plan', () {
      final pipeline = Pipeline.run(
        gradient(128, 128),
        palette: mapPalette,
        mapsX: 1,
        mapsY: 1,
      );
      final plan = pipeline.plan();
      for (final block in plan.blocks) {
        expect(block.nameZh, block.nameEn);
      }
    });

    test('rejects a solution that does not match the matched image', () {
      final pipeline = Pipeline.run(
        gradient(128, 128),
        palette: mapPalette,
        mapsX: 1,
        mapsY: 1,
      );
      final other = Pipeline.run(
        gradient(128, 128),
        palette: mapPalette,
        mapsX: 2,
        mapsY: 1,
      );
      expect(
        () => buildMapPlan(
          solution: other.solution,
          quantized: pipeline.quantized,
          palette: mapPalette,
          version: loadVersionTable().require(VersionTable.defaultVersionId),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('tile bounds cover the picture and do not run past it', () {
      final pipeline = Pipeline.run(
        gradient(128, 128),
        palette: mapPalette,
        mapsX: 2,
        mapsY: 2,
      );
      final plan = pipeline.plan();

      expect(plan.tileBounds(0, 0), (x0: 0, y0: 0, x1: 128, y1: 128));
      expect(plan.tileBounds(1, 1), (x0: 128, y0: 128, x1: 256, y1: 256));
    });
  });

  group('material list', () {
    test('a stack is 64 blocks, and 1000 is 15 stacks and 40', () {
      final line = MaterialLine(
        block: const PlanBlock(
          key: '0:0',
          blockId: 'stone',
          blockState: 'minecraft:stone',
          nameEn: 'Stone',
          nameZh: '石头',
          bright: Rgb(128, 128, 128),
          normal: Rgb(128, 128, 128),
          dark: Rgb(128, 128, 128),
        ),
        count: 1000,
      );
      expect(line.stacks, 15);
      expect(line.rest, 40);
      expect(line.stackSlots, 16);
    });

    test('an exact multiple of a stack has no remainder and no extra slot', () {
      final line = MaterialLine(
        block: planBlockStub,
        count: 128,
      );
      expect(line.stacks, 2);
      expect(line.rest, 0);
      expect(line.stackSlots, 2);
    });

    test('the list is the plan, most-used first, and the totals add up', () {
      final pipeline = Pipeline.run(
        gradient(128, 128),
        palette: mapPalette,
        mapsX: 1,
        mapsY: 1,
      );
      final plan = pipeline.plan();
      final list = materialList(plan);

      expect(list.length, plan.blocks.length);
      for (var i = 0; i < list.length; i++) {
        expect(list[i].block.key, plan.blocks[i].key);
        expect(list[i].count, plan.counts[i]);
      }

      final totals = materialTotals(plan);
      expect(totals.kinds, list.length);
      expect(totals.blocks, plan.totalBlocks);
      expect(totals.blocks, 128 * 128);
      expect(totals.stacks, 256);
      expect(totals.rest, 0);
    });

    test('reports the height range a block occupies', () {
      final pipeline = Pipeline.run(
        bands(128, 128),
        palette: mapPalette,
        mapsX: 1,
        mapsY: 1,
      );
      final plan = pipeline.plan();
      final range = heightRangeOf(plan, 0);

      expect(range.lowest, greaterThanOrEqualTo(plan.minHeight));
      expect(range.highest, lessThanOrEqualTo(plan.maxHeight));
      // A block that is in the picture must actually be somewhere in it.
      expect(range.highest, greaterThanOrEqualTo(range.lowest));
      expect(
        heightRangeOf(plan, -1),
        (lowest: 0, highest: 0),
        reason: 'a block that is not in the picture has no range',
      );
    });
  });

  group('hidden cells', () {
    test('the checkerboard is two squares across at any cell size', () {
      for (final cell in [8, 16, 32]) {
        final square = HiddenCell.squareFor(cell);
        expect(square * 2, lessThanOrEqualTo(cell + 1));
        expect(HiddenCell.at(0, 0, cell), HiddenCell.light);
        expect(HiddenCell.at(square, 0, cell), HiddenCell.dark);
        expect(HiddenCell.at(0, square, cell), HiddenCell.dark);
        expect(HiddenCell.at(square, square, cell), HiddenCell.light);
      }
    });

    test('a hidden block is painted as a checkerboard, and nothing else moves', () {
      final pipeline = Pipeline.run(
        gradient(128, 128),
        palette: mapPalette,
        mapsX: 1,
        mapsY: 1,
      );
      final plan = pipeline.plan();
      final visible = renderTexturedPlan(plan: plan, cell: 16);
      final hidden = renderTexturedPlan(
        plan: plan,
        cell: 16,
        hiddenBlocks: {0},
      );

      expect(visible.bytes.length, hidden.bytes.length);
      var changed = 0;
      for (var y = 0; y < plan.height; y++) {
        for (var x = 0; x < plan.width; x++) {
          final isHidden = plan.blockIndexAt(x, y) == 0;
          for (var dy = 0; dy < 16; dy++) {
            for (var dx = 0; dx < 16; dx++) {
              final px = x * 16 + dx;
              final py = y * 16 + dy;
              final before = visible.pixelAt(px, py);
              final after = hidden.pixelAt(px, py);
              if (isHidden) {
                expect(after, HiddenCell.at(dx, dy, 16));
                if (before != after) changed++;
              } else {
                expect(after, before, reason: 'only the hidden block changes');
              }
            }
          }
        }
      }
      // The block must actually be in the picture, or the test proves nothing.
      expect(plan.counts[0], greaterThan(0));
      expect(changed, greaterThan(0));
    });

    test('a one-pixel-per-block render uses the flat grey', () {
      final pipeline = Pipeline.run(
        gradient(128, 128),
        palette: mapPalette,
        mapsX: 1,
        mapsY: 1,
      );
      final plan = pipeline.plan();
      final hidden = renderPlanMap(plan: plan, hiddenBlocks: {0});

      for (var y = 0; y < plan.height; y++) {
        for (var x = 0; x < plan.width; x++) {
          if (plan.blockIndexAt(x, y) == 0) {
            expect(hidden.pixelAt(x, y), HiddenCell.flat);
          } else {
            expect(hidden.pixelAt(x, y), plan.colorAt(x, y));
          }
        }
      }
    });
  });
}

/// A block that is not in any picture, for the arithmetic tests that only care
/// about counts.
const PlanBlock planBlockStub = PlanBlock(
  key: '0:0',
  blockId: 'stone',
  blockState: 'minecraft:stone',
  nameEn: 'Stone',
  nameZh: '石头',
  bright: Rgb(128, 128, 128),
  normal: Rgb(110, 110, 110),
  dark: Rgb(90, 90, 90),
);
