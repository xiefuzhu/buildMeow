import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'quantize.dart';
import 'shade_tier.dart';
import 'version_table.dart';

/// How the height solver trades colour accuracy against a flatter build.
@immutable
class HeightSolverOptions {
  const HeightSolverOptions({
    this.baseHeight = 64,
    this.flatnessWeight = 5.0,
    this.freeDrift,
  });

  /// The Y level of the **lowest block of the whole build**.
  ///
  /// The surface is shifted so its lowest pixel sits here, which is what
  /// "uniformly translate to the lowest point" means. The extra north reference
  /// row ends up somewhere at or above this level; [HeightSolution] reports
  /// exactly where.
  final int baseHeight;

  /// Extra cost, per pixel, per block of drift beyond [freeDrift].
  ///
  /// Set this to zero for maximum fidelity: the solver then reproduces the
  /// image's best colour at every pixel and the height range is whatever the
  /// picture needs. That sounds attractive and is not, because each column
  /// drifts independently — a picture whose columns drift in opposite
  /// directions ends up with a build as tall as the sum of the drifts. Measured
  /// on a 128x128 diagonal gradient, the unconstrained solve spans 113 layers
  /// while a constrained one spans 64 for about 3% more colour error.
  ///
  /// The default is therefore a mild constraint. It is also what makes the
  /// world-height warning worth having: a 5x5 build can still overshoot even
  /// with the constraint on.
  final double flatnessWeight;

  /// Drift from the reference row that costs nothing, i.e. roughly half the
  /// height budget.
  ///
  /// `null` means "pick something sensible for the image size": at least 32
  /// blocks, or a quarter of the image height, whichever is larger. Without
  /// this, a 5x5 map would be given the same vertical budget as a single map
  /// and lose far more colour accuracy than it needs to.
  final int? freeDrift;

  /// The drift budget for an image [imageHeight] pixels tall.
  int effectiveFreeDrift(int imageHeight) =>
      freeDrift ?? math.max(32, imageHeight ~/ 4);
}

/// The solved staircase.
@immutable
class HeightSolution {
  const HeightSolution({
    required this.width,
    required this.height,
    required this.heights,
    required this.referenceRowHeight,
    required this.minHeight,
    required this.maxHeight,
    required this.totalCost,
    required this.windowHits,
    required this.warnings,
    required this.fitsWorld,
  });

  final int width;
  final int height;

  /// Absolute Y per map pixel, `y * width + x`, north row first.
  final Int32List heights;

  /// Absolute Y of the extra reference row that sits north of the map.
  ///
  /// The first map row's shade is decided by comparing against this row, so it
  /// has to be built even though it is not part of the picture.
  final int referenceRowHeight;

  final int minHeight;
  final int maxHeight;

  /// Sum of the CIE76 costs of the shades actually chosen.
  final double totalCost;

  /// Number of columns whose optimal path touched the solver's search window.
  /// Non-zero means the height range was capped rather than chosen.
  final int windowHits;

  final List<String> warnings;

  /// Whether the build actually fits inside the target version's world.
  ///
  /// Deliberately separate from [warnings], which also carries informational
  /// notes — a dithered build always notes that the flatness setting was
  /// ignored, and that is not a height problem.
  final bool fitsWorld;

  int heightAt(int x, int y) => heights[y * width + x];

  /// How many block layers the build spans, reference row included.
  int get blockHeightSpan {
    final lowest = math.min(minHeight, referenceRowHeight);
    final highest = math.max(maxHeight, referenceRowHeight);
    return highest - lowest + 1;
  }

  /// The shade each map pixel ends up showing, derived from the solved heights.
  ShadeTier tierAt(int x, int y) {
    final north = y == 0 ? referenceRowHeight : heightAt(x, y - 1);
    return ShadeTier.fromHeightDelta(heightAt(x, y) - north);
  }
}

/// Solves the per-column staircase.
///
/// Every column is walked north to south with a step of `-1`, `0` or `+1`
/// deciding that pixel's shade. Any sequence of steps is physically realisable,
/// so the only thing tying the pixels together is the solver's preference for a
/// compact height range — see [HeightSolverOptions.flatnessWeight].
///
/// The walk is done across the whole image, not per map tile, which is what
/// keeps the heights continuous when several maps are stitched together.
HeightSolution solveHeights({
  required QuantizedImage quantized,
  HeightSolverOptions options = const HeightSolverOptions(),
  MinecraftVersion? version,
}) {
  final width = quantized.width;
  final height = quantized.height;
  final pixelCount = width * height;
  final offsets = Int32List(pixelCount);
  final tiers = ShadeTier.staircase;
  final freeDrift = options.effectiveFreeDrift(height);

  // How much a pixel's best and worst tier can differ. Beyond `freeDrift` plus
  // this divided by the flatness weight, the drift penalty always outweighs any
  // colour saving, so those states can never be on an optimal path and the
  // search window does not need to include them. Without this bound the window
  // grows with the image and a 5x5 solve spends seconds on states that are
  // provably useless.
  var maxSpread = 0.0;
  for (var p = 0; p < pixelCount; p++) {
    var lowest = double.infinity;
    var highest = 0.0;
    for (final tier in tiers) {
      final cost = quantized.choiceCosts[tier.index][p];
      if (cost >= blockedTierCost) continue;
      if (cost < lowest) lowest = cost;
      if (cost > highest) highest = cost;
    }
    final spread = highest - lowest;
    if (spread > maxSpread) maxSpread = spread;
  }
  final extraDrift = options.flatnessWeight > 0
      ? (maxSpread / options.flatnessWeight).ceil()
      : 0;

  var windowHits = 0;
  var totalCost = 0.0;

  for (var x = 0; x < width; x++) {
    // A dithered image has exactly one legal tier per pixel, so the walk is
    // already fully determined and there is nothing for the dynamic program to
    // optimise. Running it anyway is not merely wasted work: the search window
    // would clamp the walk and force pixels onto tiers the dither forbade,
    // which wrecks the average colour the dither was buying.
    final useGreedy = options.flatnessWeight <= 0 || quantized.dithered;
    final result = useGreedy
        ? _solveColumnGreedy(quantized, x, height, tiers)
        : _solveColumnWithWindow(
            quantized,
            x,
            height,
            tiers,
            options,
            freeDrift,
            extraDrift,
          );
    for (var z = 0; z < height; z++) {
      offsets[z * width + x] = result.offsets[z];
    }
    totalCost += result.cost;
    if (result.hitWindow) windowHits++;
  }

  // Shift so the lowest map pixel sits at baseHeight. The reference row is not
  // shifted with it: it keeps its position relative to the surface, which is
  // what makes row 0's shade come out right.
  var minOffset = offsets[0];
  var maxOffset = offsets[0];
  for (final o in offsets) {
    if (o < minOffset) minOffset = o;
    if (o > maxOffset) maxOffset = o;
  }

  final shift = options.baseHeight - minOffset;
  final heights = Int32List(pixelCount);
  for (var i = 0; i < pixelCount; i++) {
    heights[i] = offsets[i] + shift;
  }

  final minHeight = minOffset + shift;
  final maxHeight = maxOffset + shift;
  final referenceRowHeight = shift;

  final warnings = <String>[];
  if (windowHits > 0) {
    warnings.add(
      '$windowHits of $width columns hit the solver height window, so their '
      'heights were capped rather than chosen',
    );
  }
  if (quantized.dithered && options.flatnessWeight > 0) {
    warnings.add(
      'dithering pins the shade of every pixel, so the flatness setting was '
      'ignored and the build is as tall as the dither needs',
    );
  }

  var fitsWorld = true;
  if (version != null) {
    final lowest = math.min(minHeight, referenceRowHeight);
    final highest = math.max(maxHeight, referenceRowHeight);
    if (lowest < version.minY || highest > version.maxY) {
      fitsWorld = false;
      warnings.add(
        'the build spans Y $lowest..$highest, which does not fit '
        '${version.id}\'s Y ${version.minY}..${version.maxY}',
      );
    }
  }

  return HeightSolution(
    width: width,
    height: height,
    heights: heights,
    referenceRowHeight: referenceRowHeight,
    minHeight: minHeight,
    maxHeight: maxHeight,
    totalCost: totalCost,
    windowHits: windowHits,
    warnings: List.unmodifiable(warnings),
    fitsWorld: fitsWorld,
  );
}

@immutable
class _ColumnResult {
  const _ColumnResult(this.offsets, this.cost, this.hitWindow);

  final Int32List offsets;
  final double cost;
  final bool hitWindow;
}

/// Exact optimum when there is no flatness pressure.
///
/// With `flatnessWeight == 0` the objective is a plain sum over pixels and every
/// step sequence is realisable, so the global optimum is just the per-pixel
/// minimum: no dynamic programming needed, and no height window to get wrong.
_ColumnResult _solveColumnGreedy(
  QuantizedImage quantized,
  int x,
  int height,
  List<ShadeTier> tiers,
) {
  final offsets = Int32List(height);
  var cost = 0.0;

  // Row 0 has no northern map pixel: its shade comes from the reference row.
  //
  // Tiers are tried in `ShadeTier.staircase` order so that the tie-break here
  // matches `bestTierAt` in the renderer. An exact tie between two shades is
  // possible for a symmetric colour, and the round-trip check would otherwise
  // disagree on those pixels.
  var bestCost = double.infinity;
  var bestOffset = 0;
  for (final tier in tiers) {
    final c = quantized.costAt(tier, x, 0);
    if (c < bestCost) {
      bestCost = c;
      bestOffset = tier.heightDelta;
    }
  }
  offsets[0] = bestOffset;
  cost += bestCost;

  for (var z = 1; z < height; z++) {
    bestCost = double.infinity;
    var bestDelta = 0;
    for (final tier in tiers) {
      final c = quantized.costAt(tier, x, z);
      if (c < bestCost) {
        bestCost = c;
        bestDelta = tier.heightDelta;
      }
    }
    offsets[z] = offsets[z - 1] + bestDelta;
    cost += bestCost;
  }

  return _ColumnResult(offsets, cost, false);
}

/// Dynamic program over `(row, height offset)` when the caller wants the build
/// kept flat. The window is bounded because the drift penalty makes anything
/// far from the reference row prohibitively expensive anyway.
_ColumnResult _solveColumnWithWindow(
  QuantizedImage quantized,
  int x,
  int height,
  List<ShadeTier> tiers,
  HeightSolverOptions options,
  int freeDrift,
  int extraDrift,
) {
  final maxDrift = math.max(freeDrift + extraDrift + 1, 32);
  final size = 2 * maxDrift + 1;
  int indexOf(int offset) => offset + maxDrift;

  double penalty(int offset) {
    final drift = offset.abs();
    return drift <= freeDrift
        ? 0.0
        : options.flatnessWeight * (drift - freeDrift);
  }

  var dp = Float64List(size)..fillRange(0, size, double.infinity);
  final back = Int32List(height * size)..fillRange(0, height * size, 0x7FFF);

  // Row 0's shade comes from the reference row, so the tier is a consequence of
  // the offset rather than a free choice.
  for (var o = -1; o <= 1; o++) {
    final tier = ShadeTier.fromHeightDelta(o);
    dp[indexOf(o)] = quantized.costAt(tier, x, 0) + penalty(o);
  }

  for (var z = 1; z < height; z++) {
    final next = Float64List(size)..fillRange(0, size, double.infinity);
    // After z steps the offset cannot be further than z + 1 from the start, so
    // only that slice of the window can hold a finite state.
    final lowest = math.max(-maxDrift, -z);
    final highest = math.min(maxDrift, z);
    for (var o = lowest; o <= highest; o++) {
      final current = dp[indexOf(o)];
      if (current == double.infinity) continue;
      for (final tier in tiers) {
        final nextOffset = o + tier.heightDelta;
        if (nextOffset < -maxDrift || nextOffset > maxDrift) continue;
        final candidate =
            current + quantized.costAt(tier, x, z) + penalty(nextOffset);
        final slot = indexOf(nextOffset);
        if (candidate < next[slot]) {
          next[slot] = candidate;
          back[z * size + slot] = o;
        }
      }
    }
    dp = next;
  }

  // Best final offset, then walk the backpointers.
  //
  // After processing row `z` the offset spans `[-(z+1), z+1]`, so the last row
  // reaches `[-height, height]`. Using `height - 1` here silently excludes the
  // best state and returns a suboptimal walk.
  var bestCost = double.infinity;
  var bestOffset = 0;
  final lastLowest = math.max(-maxDrift, -height);
  final lastHighest = math.min(maxDrift, height);
  for (var o = lastLowest; o <= lastHighest; o++) {
    if (dp[indexOf(o)] < bestCost) {
      bestCost = dp[indexOf(o)];
      bestOffset = o;
    }
  }

  var hitWindow = bestOffset.abs() >= maxDrift;

  final offsets = Int32List(height);
  offsets[height - 1] = bestOffset;
  for (var z = height - 1; z > 0; z--) {
    final previous = back[z * size + indexOf(offsets[z])];
    if (previous == 0x7FFF) {
      // Unreachable in practice: every state has a predecessor one step away.
      hitWindow = true;
      offsets[z - 1] = offsets[z];
    } else {
      offsets[z - 1] = previous;
    }
    if (offsets[z - 1].abs() >= maxDrift) hitWindow = true;
  }

  return _ColumnResult(offsets, bestCost, hitWindow);
}
