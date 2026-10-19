import 'dart:math' as math;

import 'height_map.dart';
import 'map_plan.dart';
import 'palette.dart';
import 'quantize.dart';
import 'rgb.dart';
import 'rgba_image.dart';
import 'shade_tier.dart';

/// The colour the height solver actually produces at `(x, y)`.
///
/// This is the inverse of what the solver assumes. The solver picks a shade and
/// then walks the height by `+1`, `0` or `-1` to produce it; this reads the walk
/// back and derives the shade from the step. Row `0` is compared against
/// [HeightSolution.referenceRowHeight], the extra row north of the map.
///
/// If the two ever disagree — a sign flip, an off-by-one on the reference row —
/// the round-trip test catches it, because the result stops matching the colours
/// quantization chose.
Rgb renderedColorAt({
  required HeightSolution solution,
  required QuantizedImage quantized,
  required Palette palette,
  required int x,
  required int y,
}) {
  final tier = solution.tierAt(x, y);
  final index = quantized.choiceIndices[tier.index][y * solution.width + x];
  return palette.entries[index].tone(tier);
}

/// The shade quantization would pick for `(x, y)` if heights were free.
///
/// With no flatness pressure the solver reproduces this exactly. With flatness
/// pressure it may not, and the difference is the price paid for a flatter
/// build.
ShadeTier bestTierAt(QuantizedImage quantized, int x, int y) {
  var bestCost = double.infinity;
  var bestTier = ShadeTier.staircase.first;
  for (final tier in ShadeTier.staircase) {
    final cost = quantized.costAt(tier, x, y);
    if (cost < bestCost) {
      bestCost = cost;
      bestTier = tier;
    }
  }
  return bestTier;
}

/// The colour of the unconstrained per-pixel best, i.e. what a map with no
/// staircase constraint would show.
Rgb bestColorAt({
  required QuantizedImage quantized,
  required Palette palette,
  required int x,
  required int y,
}) {
  final tier = bestTierAt(quantized, x, y);
  final index = quantized.choiceIndices[tier.index][y * quantized.width + x];
  return palette.entries[index].tone(tier);
}

/// Renders the whole map as an RGBA buffer, north row first.
///
/// Used both for the on-screen preview and for the self-consistency check: a
/// rendered image that does not match what quantization asked for means the
/// height solver and the renderer have drifted apart.
RgbaImage renderMap({
  required HeightSolution solution,
  required QuantizedImage quantized,
  required Palette palette,
}) {
  final width = solution.width;
  final height = solution.height;
  final out = RgbaImage(width, height);

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      out.setRgb(
        x,
        y,
        renderedColorAt(
          solution: solution,
          quantized: quantized,
          palette: palette,
          x: x,
          y: y,
        ),
      );
    }
  }

  return out;
}

/// The greys a hidden block is drawn as, and the checkerboard pattern itself.
///
/// Exposed as a small type rather than inlined so the on-screen blueprint
/// viewer, the exported PNG and the preview all paint the same thing: hiding a
/// block has to look the same wherever it is looked at.
///
/// A checkerboard rather than a translucent wash, because the whole point is to
/// see at a glance which cells are *not* part of the build, and a wash over a
/// dark block and a wash over a light one look nothing alike.
abstract final class HiddenCell {
  /// The two greys. Deliberately neutral: they must not read as a map colour.
  static const Rgb light = Rgb(0xc4, 0xc4, 0xc4);
  static const Rgb dark = Rgb(0x84, 0x84, 0x84);

  /// The grey a hidden cell gets when there is only one pixel per cell to draw
  /// with — a rendered map, as opposed to a textured preview.
  static const Rgb flat = Rgb(0xa4, 0xa4, 0xa4);

  /// Texels per checker square inside a cell [cell] texels on a side.
  ///
  /// Always two squares across, so the pattern is recognisable at any scale.
  static int squareFor(int cell) => math.max(2, cell ~/ 2);

  /// The colour of the square covering `(dx, dy)` within a cell.
  static Rgb at(int dx, int dy, int cell) {
    final square = squareFor(cell);
    return ((dx ~/ square) + (dy ~/ square)).isEven ? light : dark;
  }

  /// Fills the `cell * cell` region with its north-west corner at `(x0, y0)`.
  static void paint(RgbaImage out, int x0, int y0, int cell) {
    for (var dy = 0; dy < cell; dy++) {
      for (var dx = 0; dx < cell; dx++) {
        final x = x0 + dx;
        final y = y0 + dy;
        if (x >= out.width || y >= out.height) continue;
        out.setRgb(x, y, at(dx, dy, cell));
      }
    }
  }
}

/// The map colours a plan produces, one pixel per block, north row first.
///
/// The plan-based counterpart of [renderMap], and the one the app uses: the
/// same colours, derived from the same height/shade rule, but read from the
/// data the exporters and the blueprint sheets also read.
///
/// [hiddenBlocks] are indices into [MapPlan.blocks] and are painted as a single
/// neutral grey, since one pixel per block leaves no room for a pattern.
RgbaImage renderPlanMap({
  required MapPlan plan,
  Set<int> hiddenBlocks = const {},
}) {
  final out = RgbaImage(plan.width, plan.height);
  for (var y = 0; y < plan.height; y++) {
    for (var x = 0; x < plan.width; x++) {
      out.setRgb(
        x,
        y,
        hiddenBlocks.contains(plan.blockIndexAt(x, y))
            ? HiddenCell.flat
            : plan.colorAt(x, y),
      );
    }
  }
  return out;
}

/// The preview: each map pixel is that block's face texture, [cell] texels on a
/// side. A block with no texture is painted as its flat colour, so the picture
/// never has a hole.
///
/// Used both for the on-screen preview and, via [renderPlanMap], for the
/// self-consistency check: a plan that renders differently from the solution it
/// came from means the plan and the solver have drifted apart.
RgbaImage renderTexturedPlan({
  required MapPlan plan,
  RgbaImage? atlas,
  Map<String, int> textureIndex = const {},
  int cell = 16,
  int? previewCell,
  Set<int> hiddenBlocks = const {},
}) {
  final outputCell = previewCell ?? cell;
  if (cell < 1 || outputCell < 1) throw ArgumentError("cell must be positive");
  final out = RgbaImage(plan.width * outputCell, plan.height * outputCell);
  final columns = atlas == null || atlas.width < cell ? 1 : atlas.width ~/ cell;

  for (var y = 0; y < plan.height; y++) {
    for (var x = 0; x < plan.width; x++) {
      final index = plan.blockIndexAt(x, y);
      if (hiddenBlocks.contains(index)) {
        HiddenCell.paint(out, x * outputCell, y * outputCell, outputCell);
        continue;
      }
      final block = plan.blocks[index];
      final slot = textureIndex[block.blockId];
      if (atlas == null || slot == null) {
        final color = plan.colorAt(x, y);
        for (var dy = 0; dy < outputCell; dy++) {
          for (var dx = 0; dx < outputCell; dx++) {
            out.setRgb(x * outputCell + dx, y * outputCell + dy, color);
          }
        }
        continue;
      }
      final sx0 = (slot % columns) * cell;
      final sy0 = (slot ~/ columns) * cell;
      for (var dy = 0; dy < outputCell; dy++) {
        for (var dx = 0; dx < outputCell; dx++) {
          out.setRgb(
            x * outputCell + dx,
            y * outputCell + dy,
            atlas.pixelAt(
              sx0 + dx * cell ~/ outputCell,
              sy0 + dy * cell ~/ outputCell,
            ),
          );
        }
      }
    }
  }
  return out;
}

/// Counts how many pixels the solved staircase failed to reproduce.
///
/// Zero when [HeightSolverOptions.flatnessWeight] is zero, because the solver
/// then reproduces the unconstrained optimum exactly.
int countMismatchedPixels({
  required HeightSolution solution,
  required QuantizedImage quantized,
  required Palette palette,
}) {
  var mismatched = 0;
  for (var y = 0; y < solution.height; y++) {
    for (var x = 0; x < solution.width; x++) {
      final rendered = renderedColorAt(
        solution: solution,
        quantized: quantized,
        palette: palette,
        x: x,
        y: y,
      );
      final best = bestColorAt(
        quantized: quantized,
        palette: palette,
        x: x,
        y: y,
      );
      if (rendered != best) mismatched++;
    }
  }
  return mismatched;
}
