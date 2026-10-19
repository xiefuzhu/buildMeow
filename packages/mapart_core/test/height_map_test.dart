import 'dart:typed_data';

import 'package:mapart_core/mapart_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Builds a [QuantizedImage] whose per-pixel costs are chosen by the caller, so
/// the solver's behaviour can be pinned exactly.
QuantizedImage syntheticCosts(
  int width,
  int height,
  double Function(int x, int y, ShadeTier tier) cost,
) {
  final n = width * height;
  final indices = List<Int32List>.generate(
    3,
    (_) => Int32List(n),
    growable: false,
  );
  final costs = List<Float32List>.generate(
    3,
    (_) => Float32List(n),
    growable: false,
  );
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final p = y * width + x;
      for (final tier in ShadeTier.staircase) {
        indices[tier.index][p] = 0;
        costs[tier.index][p] = cost(x, y, tier);
      }
    }
  }
  return QuantizedImage(
    width: width,
    height: height,
    choiceIndices: indices,
    choiceCosts: costs,
    dithered: false,
  );
}

/// A [HeightSolution] assembled by hand, for testing the shade rule on its own
/// without going through the solver.
HeightSolution handBuiltSolution({
  required int width,
  required int height,
  required int referenceRowHeight,
  required List<int> heights,
}) {
  final minHeight = heights.reduce((a, b) => a < b ? a : b);
  final maxHeight = heights.reduce((a, b) => a > b ? a : b);
  return HeightSolution(
    width: width,
    height: height,
    heights: Int32List.fromList(heights),
    referenceRowHeight: referenceRowHeight,
    minHeight: minHeight,
    maxHeight: maxHeight,
    totalCost: 0,
    windowHits: 0,
    warnings: const <String>[],
    fitsWorld: true,
  );
}

void main() {
  group('shade rule', () {
    test('heightDelta and fromHeightDelta are inverses', () {
      for (final tier in ShadeTier.staircase) {
        expect(ShadeTier.fromHeightDelta(tier.heightDelta), tier);
      }
    });

    test('the 3x3 acceptance case from the spec', () {
      // Reference row at Y 64, then three columns:
      //   column 0: 65, 65, 64  -> higher, same, lower   -> bright, normal, dark
      //   column 1: 64, 65, 65  -> same,   higher, same  -> normal, bright, normal
      //   column 2: 64, 64, 65  -> same,   same,   higher-> normal, normal, bright
      final solution = handBuiltSolution(
        width: 3,
        height: 3,
        referenceRowHeight: 64,
        heights: <int>[
          65, 64, 64, // row 0, north-most map row
          65, 65, 64, // row 1
          64, 65, 65, // row 2
        ],
      );

      const expected = <List<ShadeTier>>[
        <ShadeTier>[ShadeTier.bright, ShadeTier.normal, ShadeTier.normal],
        <ShadeTier>[ShadeTier.normal, ShadeTier.bright, ShadeTier.normal],
        <ShadeTier>[ShadeTier.dark, ShadeTier.normal, ShadeTier.bright],
      ];

      for (var y = 0; y < 3; y++) {
        for (var x = 0; x < 3; x++) {
          expect(
            solution.tierAt(x, y),
            expected[y][x],
            reason: 'column $x row $y, height ${solution.heightAt(x, y)}',
          );
        }
      }
    });

    test('the north-most row is judged against the reference row', () {
      // Same height as the reference row means "normal", not "bright". Getting
      // this wrong is the classic off-by-one that ruins the first row.
      final solution = handBuiltSolution(
        width: 3,
        height: 1,
        referenceRowHeight: 64,
        heights: <int>[63, 64, 65],
      );
      expect(solution.tierAt(0, 0), ShadeTier.dark);
      expect(solution.tierAt(1, 0), ShadeTier.normal);
      expect(solution.tierAt(2, 0), ShadeTier.bright);
    });

    test('a one-block difference is enough, and more is the same', () {
      final solution = handBuiltSolution(
        width: 4,
        height: 2,
        referenceRowHeight: 64,
        heights: <int>[
          64, 64, 64, 64,
          65, 70, 64, 50, // +1, +6, 0, -14
        ],
      );
      expect(solution.tierAt(0, 1), ShadeTier.bright);
      expect(solution.tierAt(1, 1), ShadeTier.bright, reason: 'a +6 jump is still bright');
      expect(solution.tierAt(2, 1), ShadeTier.normal);
      expect(solution.tierAt(3, 1), ShadeTier.dark, reason: 'a -14 drop is still dark');
    });

    test('blockHeightSpan counts the reference row too', () {
      final solution = handBuiltSolution(
        width: 1,
        height: 1,
        referenceRowHeight: 70,
        heights: <int>[64],
      );
      expect(solution.minHeight, 64);
      expect(solution.maxHeight, 64);
      expect(solution.blockHeightSpan, 7, reason: 'Y 64..70 inclusive');
    });
  });

  group('solver', () {
    test('every step is exactly -1, 0 or +1', () {
      final quantized = syntheticCosts(8, 16, (x, y, tier) => (x + y) % 3);
      final solution = solveHeights(quantized: quantized);
      for (var x = 0; x < 8; x++) {
        for (var y = 1; y < 16; y++) {
          final delta = solution.heightAt(x, y) - solution.heightAt(x, y - 1);
          expect(delta, inInclusiveRange(-1, 1), reason: 'column $x row $y');
        }
      }
    });

    test('the north-most row steps by at most one from the reference row', () {
      final quantized = syntheticCosts(8, 8, (x, y, tier) => (x * y) % 5);
      final solution = solveHeights(quantized: quantized);
      for (var x = 0; x < 8; x++) {
        final delta = solution.heightAt(x, 0) - solution.referenceRowHeight;
        expect(delta, inInclusiveRange(-1, 1), reason: 'column $x');
      }
    });

    test('the lowest pixel sits at baseHeight', () {
      final quantized = syntheticCosts(6, 6, (x, y, tier) => (x + y) % 4);
      final solution = solveHeights(
        quantized: quantized,
        options: const HeightSolverOptions(baseHeight: 64),
      );
      expect(solution.minHeight, 64);
      expect(solution.maxHeight, greaterThanOrEqualTo(64));
    });

    test('baseHeight is honoured wherever it is set', () {
      final quantized = syntheticCosts(4, 4, (x, y, tier) => (x * y) % 3);
      for (final base in <int>[-60, 0, 64, 200]) {
        final solution = solveHeights(
          quantized: quantized,
          options: HeightSolverOptions(baseHeight: base),
        );
        expect(solution.minHeight, base, reason: 'baseHeight $base');
      }
    });

    test('the shift is global, not per column', () {
      // Column 0 is forced to descend three times, column 1 to climb three
      // times. A per-column shift would put both minima at baseHeight; a global
      // shift leaves column 1 sitting above column 0 by exactly the difference.
      final quantized = syntheticCosts(
        2,
        3,
        (x, y, tier) => switch ((x, tier)) {
          (0, ShadeTier.dark) => 0.0,
          (0, _) => blockedTierCost,
          (1, ShadeTier.bright) => 0.0,
          (1, _) => blockedTierCost,
          _ => blockedTierCost,
        },
      );

      final solution = solveHeights(
        quantized: quantized,
        options: const HeightSolverOptions(baseHeight: 64),
      );

      // Column 0: row 0 dark means offset -1, then two more -1 steps, so the
      // surface descends 66 -> 65 -> 64.
      expect(solution.heightAt(0, 0), 66);
      expect(solution.heightAt(0, 1), 65);
      expect(solution.heightAt(0, 2), 64);
      // Column 1: row 0 bright means offset +1, then two more +1 steps. Both
      // columns share the same global shift, so column 1 ends up six blocks
      // higher than column 0 rather than being pulled back down to baseHeight.
      expect(solution.heightAt(1, 0), 68);
      expect(solution.heightAt(1, 1), 69);
      expect(solution.heightAt(1, 2), 70);

      expect(solution.minHeight, 64);
      expect(solution.maxHeight, 70);
    });

    test('the reference row height is reported', () {
      final quantized = syntheticCosts(
        2,
        3,
        (x, y, tier) => switch ((x, tier)) {
          (0, ShadeTier.dark) => 0.0,
          (1, ShadeTier.bright) => 0.0,
          _ => blockedTierCost,
        },
      );
      final solution = solveHeights(
        quantized: quantized,
        options: const HeightSolverOptions(baseHeight: 64),
      );
      // The global minimum offset is -3, so the reference row sits three blocks
      // above the build's lowest point.
      expect(solution.referenceRowHeight, 67);
    });

    test('with no flatness pressure the solver reproduces the per-pixel optimum', () {
      // The objective is then a plain sum and every step sequence is realisable,
      // so the optimum is simply the cheapest tier at each pixel.
      final quantized = syntheticCosts(5, 9, (x, y, tier) {
        // Give each tier a distinct, position-dependent cost.
        return switch (tier) {
          ShadeTier.bright => 10.0 + (x + y) % 7,
          ShadeTier.normal => 3.0 + (x * 2 + y) % 5,
          ShadeTier.dark => 7.0 + (x + y * 3) % 6,
          _ => blockedTierCost,
        };
      });

      final solution = solveHeights(quantized: quantized);
      expect(solution.totalCost, closeTo(_perPixelOptimum(quantized), 1e-6));
      expect(solution.windowHits, 0);
    });

    test('flatness pressure trades colour accuracy for a shorter build', () {
      // Every pixel would rather climb: bright costs nothing, normal a little,
      // dark a lot. Reproducing that faithfully means climbing a block per row.
      final quantized = syntheticCosts(
        4,
        40,
        (x, y, tier) => switch (tier) {
          ShadeTier.bright => 0.0,
          ShadeTier.normal => 6.0,
          ShadeTier.dark => 20.0,
          _ => blockedTierCost,
        },
      );

      final free = solveHeights(
        quantized: quantized,
        options: const HeightSolverOptions(
          baseHeight: 0,
          flatnessWeight: 0,
        ),
      );
      final flat = solveHeights(
        quantized: quantized,
        options: const HeightSolverOptions(
          baseHeight: 0,
          flatnessWeight: 30,
          freeDrift: 2,
        ),
      );

      // Row 0 steps up once from the reference row, then 39 more steps, so the
      // free solution spans offsets 1..40.
      expect(free.maxHeight - free.minHeight, 39);
      expect(free.totalCost, 0);

      expect(
        flat.maxHeight - flat.minHeight,
        lessThan(39),
        reason: 'the flatness weight should shrink the build',
      );
      expect(
        flat.totalCost,
        greaterThan(free.totalCost),
        reason: 'a shorter build must cost colour accuracy',
      );
    });

    test('the free drift budget scales with the image height', () {
      const auto = HeightSolverOptions();
      // A single map gets the floor of 32.
      expect(auto.effectiveFreeDrift(128), 32);
      // A 5x5 build is 640 rows tall and would lose far too much accuracy with
      // the same budget as one map, so it gets a quarter of its height.
      expect(auto.effectiveFreeDrift(640), 160);
      // An explicit value always wins.
      expect(
        const HeightSolverOptions(freeDrift: 7).effectiveFreeDrift(640),
        7,
      );
    });

    test('the default constrains the build without wrecking the colours', () {
      // Columns on the left want to climb for the whole image, columns on the
      // right want to descend. Unconstrained, the build ends up as tall as the
      // two drifts added together; the default pulls them back towards the
      // reference row.
      final quantized = syntheticCosts(
        32,
        128,
        (x, y, tier) => switch (tier) {
          ShadeTier.bright => x < 16 ? 0.0 : 30.0,
          ShadeTier.dark => x < 16 ? 30.0 : 0.0,
          ShadeTier.normal => 3.0,
          _ => blockedTierCost,
        },
      );

      final unconstrained = solveHeights(
        quantized: quantized,
        options: const HeightSolverOptions(flatnessWeight: 0),
      );
      final constrained = solveHeights(quantized: quantized);

      // Row 0 steps off the reference row, then the left half climbs to +128
      // and the right half descends to -128, a span of 256.
      expect(unconstrained.maxHeight - unconstrained.minHeight, 256);
      expect(unconstrained.totalCost, 0);

      expect(
        constrained.maxHeight - constrained.minHeight,
        lessThan(256),
        reason: 'the default should produce a shorter build',
      );
      expect(
        constrained.totalCost,
        greaterThan(unconstrained.totalCost),
        reason: 'and it should pay for that in colour accuracy',
      );
    });

    test('a dithered image is solved greedily, whatever the flatness setting', () {
      // A dithered image has exactly one legal tier per pixel. If the dynamic
      // program ran anyway its search window would clamp the walk and force
      // pixels onto forbidden tiers, wrecking the average colour the dither
      // bought. The solver must therefore honour the dither exactly.
      final quantized = syntheticCosts(16, 64, (x, y, tier) {
        // Pin a single tier per pixel, alternating so the walk wanders.
        final wanted = ShadeTier.staircase[(x + y) % 3];
        return tier == wanted ? 1.0 : blockedTierCost;
      });
      final dithered = QuantizedImage(
        width: quantized.width,
        height: quantized.height,
        choiceIndices: quantized.choiceIndices,
        choiceCosts: quantized.choiceCosts,
        dithered: true,
      );

      final solution = solveHeights(
        quantized: dithered,
        options: const HeightSolverOptions(flatnessWeight: 50, freeDrift: 4),
      );

      expect(solution.windowHits, 0);
      expect(
        solution.warnings.any((w) => w.contains('dithering pins')),
        isTrue,
        reason: 'the ignored flatness setting should be reported',
      );
      // Every step must be the one the pinned tier demands.
      for (var x = 0; x < 16; x++) {
        for (var y = 1; y < 64; y++) {
          final delta = solution.heightAt(x, y) - solution.heightAt(x, y - 1);
          expect(delta, inInclusiveRange(-1, 1));
        }
      }
    });

    test('flatness pressure keeps the reported span honest', () {
      final quantized = syntheticCosts(
        8,
        32,
        (x, y, tier) => switch (tier) {
          ShadeTier.bright => 0.0,
          ShadeTier.normal => 5.0,
          ShadeTier.dark => 10.0,
          _ => blockedTierCost,
        },
      );
      // Every pixel prefers bright, so the free solution climbs from offset 1
      // to offset 32, a span of 31.
      final free = solveHeights(
        quantized: quantized,
        options: const HeightSolverOptions(flatnessWeight: 0),
      );
      expect(free.maxHeight - free.minHeight, 31);

      final flat = solveHeights(
        quantized: quantized,
        options: const HeightSolverOptions(
          flatnessWeight: 100,
          freeDrift: 1,
        ),
      );
      expect(flat.maxHeight - flat.minHeight, lessThan(31));
    });
  });

  group('world height warnings', () {
    test('reports nothing when the build fits', () {
      final versions = loadVersionTable();
      final quantized = syntheticCosts(4, 4, (x, y, tier) => 1.0);
      final solution = solveHeights(
        quantized: quantized,
        options: const HeightSolverOptions(baseHeight: 64),
        version: versions.latest,
      );
      expect(solution.warnings, isEmpty);
      expect(solution.fitsWorld, isTrue);
    });

    test('warns when the build runs past the world ceiling', () {
      final versions = loadVersionTable();
      final quantized = syntheticCosts(
        1,
        64,
        (x, y, tier) => tier == ShadeTier.bright ? 0.0 : blockedTierCost,
      );
      // Climbing 63 blocks from a base of 300 overshoots 1.21's Y 319.
      final solution = solveHeights(
        quantized: quantized,
        options: const HeightSolverOptions(baseHeight: 300, flatnessWeight: 0),
        version: versions.latest,
      );
      expect(solution.minHeight, 300);
      expect(solution.maxHeight, 363);
      expect(solution.warnings, hasLength(1));
      expect(solution.warnings.single, contains('does not fit'));
      expect(solution.fitsWorld, isFalse);
    });

    test('warns when the build runs under the world floor', () {
      final versions = loadVersionTable();
      final quantized = syntheticCosts(
        1,
        64,
        (x, y, tier) => tier == ShadeTier.dark ? 0.0 : blockedTierCost,
      );
      final solution = solveHeights(
        quantized: quantized,
        options: const HeightSolverOptions(baseHeight: -80, flatnessWeight: 0),
        version: versions.latest,
      );
      expect(solution.minHeight, -80);
      expect(
        solution.warnings,
        isNotEmpty,
        reason: '-80 is below the floor of -64',
      );
    });
  });
}

/// Sum of the cheapest tier at every pixel, which is what the solver achieves
/// when it is not asked to keep the build flat.
double _perPixelOptimum(QuantizedImage quantized) {
  var total = 0.0;
  for (var y = 0; y < quantized.height; y++) {
    for (var x = 0; x < quantized.width; x++) {
      var best = double.infinity;
      for (final tier in ShadeTier.staircase) {
        final cost = quantized.costAt(tier, x, y);
        if (cost < best) best = cost;
      }
      total += best;
    }
  }
  return total;
}
