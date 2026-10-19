import 'dart:convert';
import 'dart:io';

import 'package:mapart_core/mapart_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final table = loadColorTable().includingGameBlocks(
    loadBlockCatalog(),
    '26.1.2',
  );
  final version = loadVersionTable().latest;
  final rules = BlockCapabilities.fromJson(
    jsonDecode(File('assets/colors/block_capabilities.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final colors = loadBlockColours();

  test('production modes use their own colours and exclude unstable builds', () {
    final map = resolveProductionPalette(
      table: table,
      version: version,
      kind: ArtKind.mapItem,
      blockColors: colors,
      capabilities: rules,
    );
    final pixels = resolveProductionPalette(
      table: table,
      version: version,
      kind: ArtKind.blockPixels,
      blockColors: colors,
      capabilities: rules,
    );
    expect(map.entries.any((e) => e.blockId == 'stone'), isTrue);
    expect(pixels.entries.any((e) => e.blockId == 'stone'), isTrue);
    expect(map.ignoresShade, isFalse);
    expect(pixels.ignoresShade, isTrue);
    expect(
      pixels.entries.map((e) => e.state.toBlockStateString()).toSet().length,
      pixels.length,
      reason: 'one toggle must represent one physical texture candidate',
    );
    for (final entry in pixels.entries.where(
      (e) => e.blockId.endsWith('_log'),
    )) {
      expect(
        entry.state.properties['axis'],
        'y',
        reason: 'top textures are extracted from vertical logs',
      );
    }
    for (final palette in [map, pixels]) {
      expect(palette.entries.any((e) => e.needsSupport), isFalse);
      expect(
        palette.entries.any(
          (e) => [
            'water',
            'sand',
            'gravel',
            'white_concrete_powder',
          ].contains(e.blockId),
        ),
        isFalse,
      );
    }
    expect(
      resolveProductionPalette(
        table: table,
        version: version,
        kind: ArtKind.blockPixels,
      ).length,
      0,
      reason:
          'missing texture colours must not silently become staircase colours',
    );
  });

  for (final kind in ArtKind.values) {
    final palette = resolveProductionPalette(
      table: table,
      version: version,
      kind: kind,
      blockColors: colors,
      capabilities: rules,
    );
    final pipeline = Pipeline.run(
      gradient(16, 16),
      palette: palette,
      mapsX: 1,
      mapsY: 1,
    );
    final plan = buildMapPlan(
      solution: pipeline.solution,
      quantized: pipeline.quantized,
      palette: palette,
      version: version,
      artKind: kind,
    );
    for (final shape in ExportShape.values) {
      for (final reference in [false, true]) {
        test(
          '$kind $shape reference=$reference material counts match actual cells',
          () {
            final summary = BuildSummary.fromPlan(
              plan,
              shape: shape,
              includeReferenceRow: reference,
            );
            final structure = buildStructure(
              plan,
              shape: shape,
              includeReferenceRow: reference,
            );
            expect(summary.totalBlocks, structure.nonAirBlocks);
            expect(summary.volume, structure.volume);
            final actual = <String, int>{};
            for (final cell in structure.cells) {
              if (cell == 0) continue;
              final state = structure.palette[cell].toBlockStateString();
              actual[state] = (actual[state] ?? 0) + 1;
            }
            final listed = <String, int>{};
            for (final line in summary.materials) {
              listed.update(
                line.block.blockState,
                (n) => n + line.count,
                ifAbsent: () => line.count,
              );
            }
            expect(listed, actual);
            final itemCounts = <String, int>{};
            for (final cell in structure.cells) {
              if (cell == 0) continue;
              final id = structure.palette[cell].namespacedId;
              itemCounts.update(id, (n) => n + 1, ifAbsent: () => 1);
            }
            expect(
              summary.totals.stackSlots,
              itemCounts.values.fold<int>(
                0,
                (n, count) => n + (count + 63) ~/ 64,
              ),
            );
            expect(
              absoluteYOf(plan, 0, includeReferenceRow: reference),
              summary.baseY,
            );
            expect(() => summary.checkMemory(budget: 1), throwsStateError);
          },
        );
      }
    }
    test('$kind default reference row reflects construction', () {
      expect(
        BuildSummary.fromPlan(plan).includeReferenceRow,
        kind == ArtKind.mapItem,
      );
    });
  }
}
