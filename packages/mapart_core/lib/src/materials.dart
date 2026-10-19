import 'package:meta/meta.dart';

import 'map_plan.dart';

/// One line of the shopping list: a block and how many of it the picture uses.
@immutable
class MaterialLine {
  const MaterialLine({required this.block, required this.count});

  final PlanBlock block;
  final int count;

  /// How many full stacks of 64 that is, and what is left over.
  ///
  /// Every block a staircase mapart can use stacks to 64, so the divisor is a
  /// constant rather than a property of the block. `1000` is 15 stacks and 40
  /// loose blocks.
  int get stacks => count ~/ stackSize;
  int get rest => count % stackSize;

  static const int stackSize = 64;

  /// How many stacks you would actually carry: [stacks] plus one more when
  /// there is a remainder, because a partial stack still takes a slot.
  int get stackSlots => stacks + (rest > 0 ? 1 : 0);

  @override
  String toString() => '$count x ${block.blockId}';
}

/// The shopping list for a plan, most-used first.
///
/// Sorted by count and then by the plan's own order, which is itself
/// count-first, so this is the order the material list shows and the order the
/// CSV and the PDF print.
List<MaterialLine> materialList(MapPlan plan) => List.unmodifiable([
  for (var i = 0; i < plan.blocks.length; i++)
    MaterialLine(block: plan.blocks[i], count: plan.counts[i]),
]);

/// Totals for the header of the material list.
@immutable
class MaterialTotals {
  const MaterialTotals({
    required this.blocks,
    required this.kinds,
    required this.stacks,
    required this.rest,
    this.inventorySlots,
  });

  /// How many blocks the picture places, reference row excluded.
  final int blocks;

  /// How many distinct kinds of block that takes.
  final int kinds;

  /// [blocks] as whole stacks of 64, and the remainder.
  final int stacks;
  final int rest;
  final int? inventorySlots;

  /// How many inventory slots the whole build needs.
  int get stackSlots => inventorySlots ?? stacks + (rest > 0 ? 1 : 0);
}

MaterialTotals materialTotals(MapPlan plan) => MaterialTotals(
  blocks: plan.totalBlocks,
  kinds: plan.blocks.length,
  stacks: plan.totalBlocks ~/ MaterialLine.stackSize,
  rest: plan.totalBlocks % MaterialLine.stackSize,
  inventorySlots: materialInventorySlots(plan.blocks, plan.counts),
);

/// Orientations are separate placement states but share the same inventory item.
int materialInventorySlots(List<PlanBlock> blocks, List<int> counts) {
  final byItem = <String, int>{};
  for (var i = 0; i < blocks.length; i++) {
    byItem.update(
      blocks[i].blockId,
      (count) => count + counts[i],
      ifAbsent: () => counts[i],
    );
  }
  return byItem.values.fold<int>(0, (sum, count) => sum + (count + 63) ~/ 64);
}

/// What one block contributes to each layer, for the blueprint's height
/// annotation.
///
/// Returns the height range a block occupies, reference row included, as
/// `(lowest, highest)` absolute Y. A flat picture (texture-average palette)
/// reports a single layer; a staircase reports the span its pixels cover.
({int lowest, int highest}) heightRangeOf(MapPlan plan, int blockIndex) {
  var lowest = 1 << 30;
  var highest = -(1 << 30);
  for (var y = 0; y < plan.height; y++) {
    for (var x = 0; x < plan.width; x++) {
      if (plan.blockIndexAt(x, y) != blockIndex) continue;
      final h = plan.heightAt(x, y);
      if (h < lowest) lowest = h;
      if (h > highest) highest = h;
    }
  }
  if (lowest > highest) return (lowest: 0, highest: 0);
  return (lowest: lowest, highest: highest);
}
