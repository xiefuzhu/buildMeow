import 'dart:math' as math;

import 'map_plan.dart';
import 'materials.dart';
import 'structure/structure.dart';

/// Quantities for exactly the structure selected for export, without allocating
/// its potentially enormous air-filled cuboid.
class BuildSummary {
  BuildSummary._(
    this.plan,
    this.shape,
    this.includeReferenceRow,
    this.counts,
    this.baseY,
    this.sizeY,
  );

  factory BuildSummary.fromPlan(
    MapPlan plan, {
    ExportShape shape = ExportShape.surface,
    bool? includeReferenceRow,
  }) {
    final reference = includeReferenceRow ?? plan.requiresReferenceRow;
    final base = reference
        ? math.min(plan.minHeight, plan.referenceRowHeight)
        : plan.minHeight;
    final top = reference
        ? math.max(plan.maxHeight, plan.referenceRowHeight)
        : plan.maxHeight;
    final counts = List<int>.filled(plan.blocks.length, 0);
    for (var p = 0; p < plan.cells.length; p++) {
      counts[plan.cells[p]] += shape == ExportShape.solid
          ? plan.heights[p] - base + 1
          : 1;
    }
    if (reference) {
      final amount = shape == ExportShape.solid
          ? plan.referenceRowHeight - base + 1
          : 1;
      for (var x = 0; x < plan.width; x++) {
        counts[plan.blockIndexAt(x, 0)] += amount;
      }
    }
    return BuildSummary._(
      plan,
      shape,
      reference,
      List.unmodifiable(counts),
      base,
      top - base + 1,
    );
  }

  final MapPlan plan;
  final ExportShape shape;
  final bool includeReferenceRow;
  final List<int> counts;
  final int baseY;
  final int sizeY;
  int get totalBlocks => counts.fold(0, (sum, count) => sum + count);
  MaterialTotals get totals => MaterialTotals(
    blocks: totalBlocks,
    kinds: counts.where((c) => c > 0).length,
    stacks: totalBlocks ~/ 64,
    rest: totalBlocks % 64,
    inventorySlots: materialInventorySlots(plan.blocks, counts),
  );
  int get volume =>
      plan.width * sizeY * (plan.height + (includeReferenceRow ? 1 : 0));
  List<MaterialLine> get materials => [
    for (var i = 0; i < counts.length; i++)
      MaterialLine(block: plan.blocks[i], count: counts[i]),
  ]..sort((a, b) => b.count.compareTo(a.count));

  /// Conservative bound for the dense structure, packed data, NBT buffers,
  /// compression buffers, and retained output while writing both formats.
  int get estimatedExportBytes => volume * 20 + plan.pixelCount * 8;
  static const int defaultMemoryBudget = 1024 * 1024 * 1024;
  void checkMemory({int budget = defaultMemoryBudget}) {
    if (estimatedExportBytes > budget) {
      throw StateError(
        '投影导出预计需要 '
        '${(estimatedExportBytes / (1024 * 1024)).ceil()} MiB 内存，'
        '超过 ${budget ~/ (1024 * 1024)} MiB 预算。请减少横向或纵向张数；'
        '作品不会被裁切。',
      );
    }
  }
}
