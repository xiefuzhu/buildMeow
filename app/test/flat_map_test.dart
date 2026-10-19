import 'package:build_meow/src/data/export.dart';
import 'package:build_meow/src/data/pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapart_core/mapart_core.dart';

import 'plan_support.dart';

void main() {
  for (final dither in [DitherMode.none, DitherMode.floydSteinberg]) {
    test(
      '$dither flat map stays at one height and exports one physical layer',
      () {
        final input = buildTestRequest();
        final result = executePipeline(
          PipelineRequest(
            encodedImage: input.encodedImage,
            colorTable: input.colorTable,
            versionTable: input.versionTable,
            versionId: input.versionId,
            mapsX: 1,
            mapsY: 1,
            cropMode: CropMode.contain,
            artKind: ArtKind.mapItem,
            flatMap: true,
            dither: dither,
            ditherThreshold: input.ditherThreshold,
            metric: input.metric,
            driftBudget: input.driftBudget,
            background: input.background,
            disabledBlockKeys: {},
            includeSupportBlocks: false,
            flatnessWeight: 5,
            baseHeight: 64,
          ),
        );
        final plan = result.plan;
        expect(plan.isFlatMap, isTrue);
        expect(plan.blockHeightSpan, 1);
        expect(plan.heights.toSet(), {64});
        expect(plan.referenceRowHeight, 64);
        final normal = {
          for (final color in input.colorTable.colors)
            color.tone(ShadeTier.normal),
        };
        for (final block in plan.blocks) {
          expect(normal, contains(block.normal));
        }
        for (final shape in ExportShape.values) {
          for (final reference in [false, true]) {
            final structure = buildStructure(
              plan,
              shape: shape,
              includeReferenceRow: reference,
            );
            final summary = BuildSummary.fromPlan(
              plan,
              shape: shape,
              includeReferenceRow: reference,
            );
            expect(structure.sizeY, 1);
            expect(summary.totalBlocks, structure.nonAirBlocks);
            expect(structure.nonAirBlocks, 128 * 128 + (reference ? 128 : 0));
          }
        }
        final files = buildDataFiles(
          DataExportRequest(
            plan: plan,
            options: const ExportOptions(
              formats: {ExportFormat.schem, ExportFormat.litematic},
            ),
          ),
        );
        final schem = readNbt(
          files.firstWhere((f) => f.name.endsWith('.schem')).bytes,
        ).root;
        expect((schem['Height'] as NbtShort).value, 1);
        final litematic = readLitematic(
          files.firstWhere((f) => f.name.endsWith('.litematic')).bytes,
        );
        expect(litematic.sizeY, 1);
      },
    );
  }
}
