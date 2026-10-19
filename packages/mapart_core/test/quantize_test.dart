import 'dart:math' as math;

import 'package:mapart_core/mapart_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Builds a solid-colour image.
RgbaImage solid(int width, int height, Rgb color) {
  final image = RgbaImage(width, height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setRgb(x, y, color);
    }
  }
  return image;
}

/// A deterministic pseudo-random image, so failures are reproducible.
RgbaImage noise(int width, int height, {int seed = 12345}) {
  final random = math.Random(seed);
  final image = RgbaImage(width, height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixel(
        x,
        y,
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
      );
    }
  }
  return image;
}

void main() {
  late ColorTable table;
  late Palette palette;

  setUpAll(() {
    table = loadColorTable();
    palette = Palette.select(table, '1.20');
  });

  group('Lab conversion', () {
    test('round-trips sRGB within one 8-bit step', () {
      final failures = <String>[];
      for (var r = 0; r <= 255; r += 17) {
        for (var g = 0; g <= 255; g += 51) {
          for (var b = 0; b <= 255; b += 85) {
            final back = Lab.fromRgb(r, g, b).toRgb();
            if ((back[0] - r).abs() > 1 ||
                (back[1] - g).abs() > 1 ||
                (back[2] - b).abs() > 1) {
              failures.add('($r,$g,$b) -> $back');
            }
          }
        }
      }
      expect(failures, isEmpty, reason: failures.take(5).join('\n'));
    });

    test('black and white land where CIELAB says they should', () {
      expect(Lab.fromRgb(0, 0, 0).l, closeTo(0, 0.01));
      expect(Lab.fromRgb(255, 255, 255).l, closeTo(100, 0.01));
      final white = Lab.fromRgb(255, 255, 255);
      expect(white.a, closeTo(0, 0.01));
      expect(white.b, closeTo(0, 0.01));
    });

    test('mid grey is neutral', () {
      final grey = Lab.fromRgb(128, 128, 128);
      expect(grey.a, closeTo(0, 0.01));
      expect(grey.b, closeTo(0, 0.01));
    });

    test('distance is zero only for identical colours', () {
      final a = Lab.fromRgb(10, 20, 30);
      expect(a.distanceTo(Lab.fromRgb(10, 20, 30)), 0);
      expect(a.distanceTo(Lab.fromRgb(11, 20, 30)), greaterThan(0));
    });
  });

  group('Lanczos resampling', () {
    test('a uniform image stays uniform when shrunk', () {
      const color = Rgb(200, 40, 90);
      final resampled = resampleLanczos(solid(64, 64, color), 16, 16);
      expect(resampled.width, 16);
      expect(resampled.height, 16);
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 16; x++) {
          final p = resampled.pixelAt(x, y);
          expect((p.r - color.r).abs(), lessThanOrEqualTo(1), reason: 'at $x,$y');
          expect((p.g - color.g).abs(), lessThanOrEqualTo(1), reason: 'at $x,$y');
          expect((p.b - color.b).abs(), lessThanOrEqualTo(1), reason: 'at $x,$y');
        }
      }
    });

    test('a uniform image stays uniform when enlarged', () {
      const color = Rgb(12, 240, 30);
      final resampled = resampleLanczos(solid(8, 8, color), 32, 32);
      for (var y = 0; y < 32; y++) {
        for (var x = 0; x < 32; x++) {
          final p = resampled.pixelAt(x, y);
          expect((p.r - color.r).abs(), lessThanOrEqualTo(1));
          expect((p.g - color.g).abs(), lessThanOrEqualTo(1));
          expect((p.b - color.b).abs(), lessThanOrEqualTo(1));
        }
      }
    });

    test('an integer-factor downscale reproduces a linear ramp', () {
      // A symmetric, normalised filter passes linear signals through untouched:
      // the weighted average of a straight line is the line's value at the
      // filter's centre. That is the property that stops smooth gradients from
      // banding, and it holds for any kernel width.
      //
      // Slope 2 keeps the ramp inside 0..255 so nothing gets clamped.
      final image = RgbaImage(64, 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 64; x++) {
          final v = 2 * x;
          image.setPixel(x, y, v, v, v);
        }
      }

      final resampled = resampleLanczos(image, 16, 1);
      // Output pixel x is centred on source coordinate 4x + 2, so a linear ramp
      // of slope 2 must read 2 * (4x + 2) = 8x + 4.
      //
      // The first and last few columns are excluded because edge replication
      // breaks the symmetry there.
      for (var x = 3; x <= 12; x++) {
        expect(
          resampled.pixelAt(x, 0).r,
          closeTo(8 * x + 4, 2),
          reason: 'output column $x of a linear ramp',
        );
      }
    });

    test('a hard edge is blended across, not sampled as a hard step', () {
      // A 64 -> 2 downscale has to integrate over large regions. The left
      // output pixel covers the black half but its kernel reaches into the
      // white half, so it lands above zero rather than snapping to it.
      final image = RgbaImage(64, 64);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final v = x < 32 ? 0 : 255;
          image.setPixel(x, y, v, v, v);
        }
      }
      final resampled = resampleLanczos(image, 2, 2);
      final left = resampled.pixelAt(0, 0).r;
      final right = resampled.pixelAt(1, 0).r;
      expect(left, lessThan(right));
      expect(left, lessThan(64), reason: 'the black half must stay dark');
      expect(right, greaterThan(191), reason: 'the white half must stay light');
    });

    test('a big downscale does not alias into stripes', () {
      // A one-pixel checkerboard averaged down must come out flat mid grey,
      // not a noisy mess.
      final image = RgbaImage(128, 128);
      for (var y = 0; y < 128; y++) {
        for (var x = 0; x < 128; x++) {
          final v = (x + y).isEven ? 0 : 255;
          image.setPixel(x, y, v, v, v);
        }
      }
      final resampled = resampleLanczos(image, 8, 8);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          expect(
            resampled.pixelAt(x, y).r,
            closeTo(128, 8),
            reason: 'checkerboard should average to mid grey at $x,$y',
          );
        }
      }
    });

    test('returns a copy unchanged when the size already matches', () {
      final image = noise(4, 4);
      final same = resampleLanczos(image, 4, 4);
      expect(same.bytes, image.bytes);
      expect(identical(same.bytes, image.bytes), isFalse);
    });
  });

  group('fitToGrid', () {
    test('cover fills the grid exactly and crops the overflow', () {
      // 200x100 into 64x64: scale 0.64, giving 128x64, then a centred crop.
      final result = fitToGrid(
        solid(200, 100, const Rgb(1, 2, 3)),
        64,
        64,
        mode: CropMode.cover,
        background: const Rgb(255, 255, 255),
      );
      expect(result.width, 64);
      expect(result.height, 64);
      expect(result.pixelAt(0, 0), const Rgb(1, 2, 3));
    });

    test('contain fits inside and pads with the background', () {
      // 200x100 into 64x64: scale 0.32, giving 64x32, then bands top and bottom.
      final result = fitToGrid(
        solid(200, 100, const Rgb(1, 2, 3)),
        64,
        64,
        mode: CropMode.contain,
        background: const Rgb(255, 255, 255),
      );
      expect(result.width, 64);
      expect(result.height, 64);
      expect(result.pixelAt(0, 0), const Rgb(255, 255, 255));
      expect(result.pixelAt(0, 63), const Rgb(255, 255, 255));
      expect(result.pixelAt(32, 32), const Rgb(1, 2, 3));
    });

    test('contain of a square image leaves no bands', () {
      final result = fitToGrid(
        solid(50, 50, const Rgb(9, 9, 9)),
        64,
        64,
        mode: CropMode.contain,
        background: const Rgb(255, 255, 255),
      );
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          expect(result.pixelAt(x, y), const Rgb(9, 9, 9), reason: 'at $x,$y');
        }
      }
    });

    test('handles a non-square target grid', () {
      // Two maps wide, one tall.
      final result = fitToGrid(
        noise(100, 100, seed: 7),
        256,
        128,
        mode: CropMode.cover,
        background: const Rgb(0, 0, 0),
      );
      expect(result.width, 256);
      expect(result.height, 128);
    });
  });

  group('quantization', () {
    test('an exact palette tone is matched with zero error', () {
      final entry = palette.forColor(13)!;
      for (final tier in ShadeTier.staircase) {
        final tone = entry.tone(tier);
        final quantized = quantize(
          source: solid(1, 1, tone),
          palette: palette,
        );
        final index = quantized.choiceIndices[tier.index][0];
        expect(
          palette.entries[index].tone(tier),
          tone,
          reason: 'a colour straight out of the palette must be an exact hit',
        );
        expect(quantized.costAt(tier, 0, 0), closeTo(0, 1e-6));
      }
    });

    test('every pixel gets a choice at every tier', () {
      final quantized = quantize(source: noise(16, 16), palette: palette);
      for (final tier in ShadeTier.staircase) {
        final indices = quantized.choiceIndices[tier.index];
        expect(indices.length, 256);
        for (final index in indices) {
          expect(index, inInclusiveRange(0, palette.length - 1));
        }
      }
    });

    test('no cost ever exceeds the blocked sentinel', () {
      final quantized = quantize(source: noise(16, 16), palette: palette);
      for (final tier in ShadeTier.staircase) {
        for (final cost in quantized.choiceCosts[tier.index]) {
          expect(cost, lessThanOrEqualTo(blockedTierCost));
        }
      }
    });

    test('a black image picks the darkest available option', () {
      final quantized = quantize(
        source: solid(2, 2, const Rgb(0, 0, 0)),
        palette: palette,
      );
      // Every tier must settle on the darkest colour in the palette, which is
      // the dark tone of Black Wool.
      final blackWool = palette.forColor(28)!;
      for (final tier in ShadeTier.staircase) {
        final index = quantized.choiceIndices[tier.index][0];
        expect(palette.entries[index].name, blackWool.name);
      }
    });

    test('a restricted palette is respected', () {
      final restricted = palette.only({13, 28});
      final quantized = quantize(source: noise(8, 8), palette: restricted);
      expect(restricted.length, 2);
      for (final tier in ShadeTier.staircase) {
        for (final index in quantized.choiceIndices[tier.index]) {
          expect(index, inInclusiveRange(0, 1));
        }
      }
    });

    test('an empty palette is rejected rather than producing nonsense', () {
      expect(
        () => quantize(source: solid(1, 1, const Rgb(0, 0, 0)), palette: palette.only(<int>{})),
        throwsArgumentError,
      );
    });

    test('transparent pixels are flattened onto the background', () {
      final image = RgbaImage(1, 1)..setPixel(0, 0, 0, 0, 0, 0);
      final quantized = quantize(
        source: image,
        palette: palette,
        options: const QuantizeOptions(background: Rgb(255, 255, 255)),
      );
      // White must land on the White Wool colour at some tier.
      final index = quantized.choiceIndices[ShadeTier.bright.index][0];
      expect(palette.entries[index].name, 'White Wool');
    });

    test('dithering pins exactly one tier per pixel', () {
      final quantized = quantize(
        source: noise(16, 16, seed: 99),
        palette: palette,
        options: const QuantizeOptions(dither: DitherMode.floydSteinberg),
      );
      expect(quantized.dithered, isTrue);
      for (var p = 0; p < quantized.pixelCount; p++) {
        final allowed = ShadeTier.staircase
            .where((t) => quantized.choiceCosts[t.index][p] < blockedTierCost)
            .length;
        expect(allowed, 1, reason: 'pixel $p should have exactly one tier');
      }
    });

    test('dithering still leaves every tier usable across the image', () {
      final quantized = quantize(
        source: noise(32, 32, seed: 5),
        palette: palette,
        options: const QuantizeOptions(dither: DitherMode.floydSteinberg),
      );
      final used = <int>{};
      for (var p = 0; p < quantized.pixelCount; p++) {
        for (final tier in ShadeTier.staircase) {
          if (quantized.choiceCosts[tier.index][p] < blockedTierCost) {
            used.add(tier.index);
          }
        }
      }
      // A random image should exercise all three shades; if only one showed up
      // the error diffusion is not actually running.
      expect(used.length, greaterThan(1));
    });

    test('without dithering every tier stays available', () {
      final quantized = quantize(source: noise(8, 8), palette: palette);
      expect(quantized.dithered, isFalse);
      for (final tier in ShadeTier.staircase) {
        for (final cost in quantized.choiceCosts[tier.index]) {
          expect(cost, lessThan(blockedTierCost));
        }
      }
    });
  });

  group('chroma-weighted matching', () {
    test('a pale chromatic colour keeps its hue instead of going grey', () {
      // The regression this exists for: pastel cyan sits far from every map
      // colour, and plain CIE76 hands it to a near-neutral grey because grey
      // is close in lightness. The picture then reads drab even though a
      // same-hue colour was available.
      const paleCyan = Rgb(178, 235, 240);

      Rgb pick(ColorMetric metric) {
        final quantized = quantize(
          source: solid(1, 1, paleCyan),
          palette: palette,
          options: QuantizeOptions(metric: metric),
        );
        final index = quantized.choiceIndices[ShadeTier.bright.index][0];
        return palette.entries[index].tone(ShadeTier.bright);
      }

      final standard = pick(ColorMetric.cie76);
      final weighted = pick(ColorMetric.chromaWeighted);

      final spread = math.max(
        standard.r,
        math.max(standard.g, standard.b),
      ) - math.min(standard.r, math.min(standard.g, standard.b));
      expect(spread, lessThan(16), reason: 'cie76 pick $standard should be grey');

      // The weighted pick must be on the blue-green side: blue and green both
      // clearly above red.
      expect(weighted.b, greaterThan(weighted.r + 20));
      expect(weighted.g, greaterThan(weighted.r + 20));
    });

    test('an achromatic colour is matched exactly as before', () {
      // No chroma, no penalty: the metric degenerates to plain CIE76.
      const grey = Rgb(140, 140, 140);
      int pick(ColorMetric metric) => quantize(
        source: solid(1, 1, grey),
        palette: palette,
        options: QuantizeOptions(metric: metric),
      ).choiceIndices[ShadeTier.bright.index][0];
      expect(
        pick(ColorMetric.chromaWeighted),
        pick(ColorMetric.cie76),
      );
    });

    test('OkLab still hands pale cyan to grey, same as CIE76', () {
      // OkLab's Euclidean distance prefers the light grey too. It is not a
      // substitute for the chroma penalty. White is L = 1, which just checks
      // the conversion.
      expect(OkLab.fromRgb(255, 255, 255).l, closeTo(1, 1e-3));
      expect(OkLab.fromRgb(0, 0, 0).l, closeTo(0, 1e-6));

      const paleCyan = Rgb(178, 235, 240);
      final quantized = quantize(
        source: solid(1, 1, paleCyan),
        palette: palette,
        options: const QuantizeOptions(metric: ColorMetric.oklab),
      );
      final color = bestColorAt(
        quantized: quantized,
        palette: palette,
        x: 0,
        y: 0,
      );
      final spread = math.max(color.r, math.max(color.g, color.b)) -
          math.min(color.r, math.min(color.g, color.b));
      expect(spread, lessThan(16), reason: 'oklab pick $color should be grey');
    });
  });

  group('dither threshold', () {
    /// How many pixels the dither actually pinned.
    int ditheredPixels(QuantizedImage quantized) {
      var count = 0;
      for (var p = 0; p < quantized.pixelCount; p++) {
        for (final tier in ShadeTier.staircase) {
          if (quantized.choiceCosts[tier.index][p] < blockedTierCost) {
            count++;
            break;
          }
        }
      }
      return count;
    }

    test('threshold zero dithers every pixel', () {
      final quantized = quantize(
        source: noise(16, 16),
        palette: palette,
        options: const QuantizeOptions(
          dither: DitherMode.floydSteinberg,
          ditherThreshold: 0,
        ),
      );
      expect(ditheredPixels(quantized), quantized.pixelCount);
    });

    test('a threshold above every error leaves the picture undithered', () {
      // This is the switch that keeps flat regions flat: if nothing is far
      // enough from the palette, nothing should be textured.
      final quantized = quantize(
        source: noise(16, 16),
        palette: palette,
        options: const QuantizeOptions(
          dither: DitherMode.floydSteinberg,
          ditherThreshold: 1000,
        ),
      );
      expect(ditheredPixels(quantized), quantized.pixelCount);
      // Every pixel still gets a legal choice; the ramp only zeroes the
      // diffusion, it does not disable the pinning.
      for (var p = 0; p < quantized.pixelCount; p++) {
        final allowed = ShadeTier.staircase
            .where((t) => quantized.choiceCosts[t.index][p] < blockedTierCost)
            .length;
        expect(allowed, 1);
      }
    });

    test('a flat picture the palette can hit exactly stays clean', () {
      // White Wool bright is the brightest map colour, so a white image is an
      // exact hit and must not be textured at all.
      final white = Rgb(255, 255, 255);
      final quantized = quantize(
        source: solid(16, 16, white),
        palette: palette,
        options: const QuantizeOptions(dither: DitherMode.floydSteinberg),
      );
      final mismatched = countMismatchedPixels(
        solution: solveHeights(quantized: quantized),
        quantized: quantized,
        palette: palette,
      );
      expect(mismatched, 0);
      expect(quantized.costAt(ShadeTier.bright, 0, 0), closeTo(0, 1e-6));
    });

    test('error from a mismatched neighbour does not stipple a clean region', () {
      // The regression this exists for: the ramp used to be measured on the
      // error-shifted target instead of on the source pixel, so error arriving
      // from a region the palette cannot reach re-armed the diffusion at every
      // pixel it crossed. On a real illustration that turned a white shirt into
      // a field of blue dots even though white is in the palette exactly.
      //
      // The scan runs west to east, so the unreachable colour goes on the left
      // and the clean one on the right: the error has to travel *into* the
      // region that should stay flat for the bug to show at all.
      //
      // The clean half is deliberately a few deltaE off a palette colour rather
      // than exactly on one. That is what the real illustration looks like — its
      // near-white averages (245,245,250), about 3 deltaE from White Wool bright
      // — and it is what makes the accumulation possible: once the neighbour's
      // error has pushed a pixel past the threshold, every further pixel in the
      // run adds its own small miss on top, until the choice flips and leaves a
      // dot. An exactly-white half has nothing to add and stays clean even with
      // the bug, which is why this test does not use one.
      const size = 32;
      final image = RgbaImage(size, size);
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          image.setRgb(
            x,
            y,
            x < size ~/ 2
                ? const Rgb(200, 232, 248) // pale cyan, 14+ deltaE away
                : const Rgb(245, 245, 250), // near-white, ~3 deltaE away
          );
        }
      }

      final quantized = quantize(
        source: image,
        palette: palette,
        options: const QuantizeOptions(dither: DitherMode.floydSteinberg),
      );
      final rendered = renderMap(
        solution: solveHeights(quantized: quantized),
        quantized: quantized,
        palette: palette,
      );

      // Skip the couple of columns the boundary's error can legitimately reach.
      final colours = <Rgb>{};
      for (var y = 0; y < size; y++) {
        for (var x = size ~/ 2 + 4; x < size; x++) {
          colours.add(rendered.pixelAt(x, y));
        }
      }
      expect(colours, hasLength(1), reason: 'stippled: $colours');
      expect(colours.single, const Rgb(255, 255, 255));
    });
  });

  group('drift budget', () {
    /// A picture whose pale blue is unreachable, so the dither has to work and
    /// the walk is free to wander.
    RgbaImage paleBlue(int size) => solid(size, size, const Rgb(200, 232, 248));

    test('the suggested plan fits the world', () {
      final versions = loadVersionTable();
      for (final version in versions.versions) {
        final plan = suggestHeightPlan(version);
        final span = 2 * plan.driftBudget + 1;
        expect(
          plan.baseHeight + span - 1,
          lessThanOrEqualTo(version.maxY),
          reason: '${version.id} ceiling',
        );
        expect(
          plan.baseHeight,
          greaterThanOrEqualTo(version.minY),
          reason: '${version.id} floor',
        );
      }
    });

    test('the plan leaves a single map alone when it already fits', () {
      final versions = loadVersionTable();
      final version = versions.latest;
      final plan = suggestHeightPlan(version);

      final unbounded = solveHeights(
        quantized: quantize(
          source: paleBlue(64),
          palette: palette,
          options: const QuantizeOptions(dither: DitherMode.floydSteinberg),
        ),
        options: HeightSolverOptions(baseHeight: plan.baseHeight),
        version: version,
      );
      final budgeted = solveHeights(
        quantized: quantize(
          source: paleBlue(64),
          palette: palette,
          options: QuantizeOptions(
            dither: DitherMode.floydSteinberg,
            driftBudget: plan.driftBudget,
          ),
        ),
        options: HeightSolverOptions(baseHeight: plan.baseHeight),
        version: version,
      );

      expect(budgeted.maxHeight, unbounded.maxHeight);
      expect(budgeted.fitsWorld, isTrue);
    });

    test('a tight budget bounds the build', () {
      final quantized = quantize(
        source: paleBlue(64),
        palette: palette,
        options: const QuantizeOptions(
          dither: DitherMode.floydSteinberg,
          driftBudget: 4,
        ),
      );
      final solution = solveHeights(
        quantized: quantized,
        options: const HeightSolverOptions(baseHeight: 0),
      );
      // Span is at most 2 * budget + 1 by construction.
      expect(solution.maxHeight - solution.minHeight, lessThanOrEqualTo(9));
    });

    test('a tight budget costs colour accuracy', () {
      final loose = quantize(
        source: paleBlue(64),
        palette: palette,
        options: const QuantizeOptions(dither: DitherMode.floydSteinberg),
      );
      final tight = quantize(
        source: paleBlue(64),
        palette: palette,
        options: const QuantizeOptions(
          dither: DitherMode.floydSteinberg,
          driftBudget: 4,
        ),
      );

      /// Mean CIE76 error of a 4x4 box average of both images.
      ///
      /// Deliberately not per pixel. Dithering is *supposed* to raise the
      /// per-pixel error — that is how it buys a better neighbourhood average —
      /// so a per-pixel figure cannot show what a restricted budget costs. It
      /// in fact moves the other way: a budget so tight the dither cannot swing
      /// between shades lands every pixel nearer its own target, while the
      /// region as a whole drifts further off.
      double blurredMean(QuantizedImage quantized) {
        final solution = solveHeights(
          quantized: quantized,
          options: const HeightSolverOptions(baseHeight: 0),
        );
        final rendered = renderMap(
          solution: solution,
          quantized: quantized,
          palette: palette,
        );
        final target = paleBlue(64);

        Rgb average(RgbaImage image, int x0, int y0) {
          var r = 0, g = 0, b = 0;
          for (var y = y0; y < y0 + 4; y++) {
            for (var x = x0; x < x0 + 4; x++) {
              final p = image.pixelAt(x, y);
              r += p.r;
              g += p.g;
              b += p.b;
            }
          }
          return Rgb(r ~/ 16, g ~/ 16, b ~/ 16);
        }

        var total = 0.0;
        var blocks = 0;
        for (var y = 0; y < 64; y += 4) {
          for (var x = 0; x < 64; x += 4) {
            final a = average(target, x, y);
            final b = average(rendered, x, y);
            total += Lab.fromRgb(a.r, a.g, a.b).distanceTo(
              Lab.fromRgb(b.r, b.g, b.b),
            );
            blocks++;
          }
        }
        return total / blocks;
      }

      expect(blurredMean(tight), greaterThan(blurredMean(loose)));
    });

    test('the budget never leaves a pixel without a choice', () {
      final quantized = quantize(
        source: noise(16, 16),
        palette: palette,
        options: const QuantizeOptions(
          dither: DitherMode.floydSteinberg,
          driftBudget: 1,
        ),
      );
      for (var p = 0; p < quantized.pixelCount; p++) {
        final allowed = ShadeTier.staircase
            .where((t) => quantized.choiceCosts[t.index][p] < blockedTierCost)
            .length;
        expect(allowed, greaterThanOrEqualTo(1), reason: 'pixel $p');
      }
    });
  });

  group('halftone', () {
    // The pale cyan the palette has no single colour for. See colour_fidelity.md.
    const hair = Rgb(178, 235, 240);

    int legalTiers(QuantizedImage quantized, int p) {
      var n = 0;
      for (final tier in ShadeTier.staircase) {
        if (quantized.costAt(tier, p % quantized.width, p ~/ quantized.width) <
            blockedTierCost) {
          n++;
        }
      }
      return n;
    }

    test('a pastel fill mixes two normal-shade colours and stays one block tall', () {
      final source = solid(32, 48, hair);
      final quantized = quantize(
        source: source,
        palette: palette,
        options: const QuantizeOptions(
          dither: DitherMode.halftone,
          metric: ColorMetric.chromaWeighted,
          ditherThreshold: 0,
        ),
      );
      expect(quantized.dithered, isFalse);

      final used = <int>{};
      for (var p = 0; p < quantized.pixelCount; p++) {
        expect(legalTiers(quantized, p), 1, reason: 'pixel $p');
        expect(
          quantized.costAt(ShadeTier.normal, p % 32, p ~/ 32),
          lessThan(blockedTierCost),
        );
        used.add(quantized.paletteIndexAt(ShadeTier.normal, p % 32, p ~/ 32));
      }
      expect(used.length, 2, reason: 'a mix needs both colours, got $used');

      final solution = solveHeights(quantized: quantized);
      expect(solution.blockHeightSpan, 1);

      final rendered = renderMap(
        solution: solution,
        quantized: quantized,
        palette: palette,
      );
      final colors = <int>{};
      for (var y = 0; y < rendered.height; y++) {
        for (var x = 0; x < rendered.width; x++) {
          final c = rendered.pixelAt(x, y);
          colors.add((c.r << 16) | (c.g << 8) | c.b);
          expect(solution.tierAt(x, y), ShadeTier.normal);
        }
      }
      expect(colors.length, 2);
    });

    test('white, which the palette already has, is not textured', () {
      final quantized = quantize(
        source: solid(16, 16, const Rgb(255, 255, 255)),
        palette: palette,
        options: const QuantizeOptions(
          dither: DitherMode.halftone,
          metric: ColorMetric.chromaWeighted,
        ),
      );
      for (var p = 0; p < quantized.pixelCount; p++) {
        expect(legalTiers(quantized, p), ShadeTier.staircase.length);
      }
    });

    test('the same pastel is flatter than Floyd-Steinberg', () {
      final source = solid(32, 48, hair);
      int span(DitherMode mode) {
        final quantized = quantize(
          source: source,
          palette: palette,
          options: QuantizeOptions(
            dither: mode,
            metric: ColorMetric.chromaWeighted,
            ditherThreshold: 0,
          ),
        );
        return solveHeights(
          quantized: quantized,
          options: HeightSolverOptions(
            flatnessWeight: quantized.dithered ? 0 : 5,
          ),
        ).blockHeightSpan;
      }

      expect(span(DitherMode.halftone), 1);
      expect(span(DitherMode.floydSteinberg), greaterThan(1));
    });
  });

  group('block cap', () {
    test('a cap uses no more blocks, and the indices stay valid', () {
      final source = noise(48, 48);
      final uncapped = quantize(source: source, palette: palette);
      final capped = quantize(
        source: source,
        palette: palette,
        options: const QuantizeOptions(maxBlocks: 12),
      );

      final used = <int>{};
      for (var p = 0; p < capped.pixelCount; p++) {
        for (final tier in ShadeTier.staircase) {
          final index = capped.choiceIndices[tier.index][p];
          expect(index, inInclusiveRange(0, palette.length - 1));
          if (capped.choiceCosts[tier.index][p] < blockedTierCost) {
            used.add(index);
          }
        }
      }
      expect(used.length, lessThanOrEqualTo(12));
      expect(uncapped.pixelCount, capped.pixelCount);

      // The capped picture is a real picture, not a mangled one: its total
      // error has to stay in the same order of magnitude as the uncapped run.
      // The remap bug this guards against read the survivors' colours under
      // the full palette's names, which inflated the error roughly tenfold.
      double total(QuantizedImage q) {
        var sum = 0.0;
        for (var p = 0; p < q.pixelCount; p++) {
          var best = double.infinity;
          for (final tier in ShadeTier.staircase) {
            final cost = q.costAt(tier, p % q.width, p ~/ q.width);
            if (cost < best) best = cost;
          }
          sum += best;
        }
        return sum;
      }

      expect(total(capped), lessThan(total(uncapped) * 3));
    });

    test('a cap at or above the palette length changes nothing', () {
      final source = noise(16, 16);
      final plain = quantize(source: source, palette: palette);
      final same = quantize(
        source: source,
        palette: palette,
        options: QuantizeOptions(maxBlocks: palette.length),
      );
      for (var k = 0; k < ShadeTier.staircase.length; k++) {
        expect(same.choiceIndices[k], plain.choiceIndices[k]);
      }
    });

    test('a cap above the number of blocks actually used changes nothing', () {
      // The mapping error this guards against only shows up once the second
      // pass runs, so the interesting case is a cap that is high enough to
      // keep every block the first pass used: then the two passes must agree
      // exactly with no cap at all.
      final source = noise(32, 32);
      final plain = quantize(source: source, palette: palette);

      final used = <int>{};
      for (var p = 0; p < plain.pixelCount; p++) {
        for (final tier in ShadeTier.staircase) {
          if (plain.choiceCosts[tier.index][p] < blockedTierCost) {
            used.add(plain.choiceIndices[tier.index][p]);
          }
        }
      }

      final capped = quantize(
        source: source,
        palette: palette,
        options: QuantizeOptions(maxBlocks: used.length),
      );
      for (var k = 0; k < ShadeTier.staircase.length; k++) {
        expect(capped.choiceIndices[k], plain.choiceIndices[k]);
      }
    });
  });

  group('texture colours', () {
    test('shade is not searched, and the build is one flat layer', () {
      final textured = Palette.blocks(table, '1.20').withBlockColors(const {
        'white_wool': 0xF7F7F7,
        'orange_wool': 0xE58A2A,
      });
      expect(textured.ignoresShade, isTrue);
      expect(palette.ignoresShade, isFalse);

      final source = solid(8, 24, const Rgb(0xE5, 0x8A, 0x2A));
      for (final dither in [DitherMode.none, DitherMode.floydSteinberg]) {
        final quantized = quantize(
          source: source,
          palette: textured,
          options: QuantizeOptions(
            dither: dither,
            metric: ColorMetric.chromaWeighted,
          ),
        );
        for (var y = 0; y < quantized.height; y++) {
          for (var x = 0; x < quantized.width; x++) {
            expect(
              quantized.costAt(ShadeTier.normal, x, y),
              lessThan(blockedTierCost),
            );
            expect(
              quantized.costAt(ShadeTier.bright, x, y),
              blockedTierCost,
            );
            expect(quantized.costAt(ShadeTier.dark, x, y), blockedTierCost);
          }
        }
        final solution = solveHeights(
          quantized: quantized,
          options: HeightSolverOptions(
            flatnessWeight: quantized.dithered ? 0 : 5,
          ),
        );
        expect(solution.blockHeightSpan, 1, reason: dither.name);
        final y0 = solution.heightAt(0, 0);
        for (var y = 0; y < solution.height; y++) {
          for (var x = 0; x < solution.width; x++) {
            expect(solution.heightAt(x, y), y0);
          }
        }
      }
    });
  });
}
