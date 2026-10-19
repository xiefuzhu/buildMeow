import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'lab.dart';
import 'palette.dart';
import 'rgb.dart';
import 'rgba_image.dart';
import 'shade_tier.dart';
import 'version_table.dart';

/// How "close" two colours are judged to be.
enum ColorMetric {
  /// CIE76, plain Euclidean distance in Lab. Cheap, and tends to prefer a
  /// neutral colour over a slightly tinted one for pale, low-chroma targets.
  cie76,

  /// CIEDE2000. Roughly ten times the work, and noticeably better behaved for
  /// pale and low-chroma colours — which matters a lot here, because the map
  /// palette is mostly saturated and a picture's pale regions have to land on
  /// something.
  ciede2000,

  /// CIE76 plus a penalty on candidates that are *less* chromatic than the
  /// target.
  ///
  /// The failure this addresses: a pale but clearly coloured target — pastel
  /// cyan hair, say — sits far from every palette colour, and plain CIE76
  /// hands it to the nearest *grey*, because grey is close in lightness and
  /// the chroma difference is only one term of the distance. The picture then
  /// reads as drab even though a same-hue colour (saturated turquoise for the
  /// cyan) was available and reads far better.
  ///
  /// The penalty is `(targetChroma - candidateChroma)^2` when positive, zero
  /// otherwise: candidates at least as colourful as the target are unaffected,
  /// so achromatic targets behave exactly as [cie76] and only washed-out
  /// matches for colourful targets are pushed away. The weight is fixed at 1,
  /// which measured indistinguishable from [ciede2000] on the problem cases
  /// (`tool/color_lab.dart`) at the cost of two multiplies.
  chromaWeighted,

  /// Euclidean distance in OkLab.
  ///
  /// Tried as a replacement for [chromaWeighted]. On pale cyan it ranks light
  /// grey closer than turquoise (OkLab distance 0.059 against 0.101), so the
  /// flat pick is `#dcdcdc`, the same failure CIE76 has. With Floyd-Steinberg
  /// on the illustration, 5×5 blurred CIE76 is 4.78 against 2.70 for
  /// [chromaWeighted], and the sample pixel stays grey. Not offered in the
  /// app. Re-run with `tool/metric_probe.dart`.
  oklab,
}

/// How quantization error is spread across neighbouring pixels.
enum DitherMode {
  /// Pick the nearest colour for each pixel independently. Leaves the height
  /// solver free to choose any shade, which keeps the build flat.
  none,

  /// Floyd-Steinberg error diffusion.
  ///
  /// Better gradients, at the cost of locking each pixel's shade: the solver no
  /// longer gets to pick the shade, so the height range can wander more.
  floydSteinberg,

  /// Two map colours, both at the normal shade, placed by blue noise.
  ///
  /// Measured, and not a replacement for [floydSteinberg]. A flat column can
  /// only show the normal shade — bright and dark exist on slopes — so the
  /// mix's "white" is `#dcdcdc`, not `#ffffff`, and a pale cyan stays far from
  /// the target. On a flat `#b2ebf0` fill the build is 1 layer tall against
  /// Floyd-Steinberg's 65, but the 5×5 blurred error is about 17 against
  /// about 5. On the illustration used in `doc/colour_fidelity.md`, even with
  /// the threshold off, blurred error stays with the undithered picture
  /// (about 8) and the height barely moves. Kept so the measurement can be
  /// re-run from `tool/halftone_probe.dart`; the app does not offer it.
  halftone,
}

@immutable
class QuantizeOptions {
  const QuantizeOptions({
    this.dither = DitherMode.none,
    this.background = const Rgb(255, 255, 255),
    this.ditherStrength = 1.0,
    this.metric = ColorMetric.cie76,
    this.ditherThreshold = 8.0,
    this.driftBudget,
    this.maxBlocks,
    this.neutralChromaWeight = 0,
    this.neutralChromaBelow = 8,
  });

  final DitherMode dither;

  /// What transparent areas are flattened onto before colour matching.
  final Rgb background;

  /// How much of each pixel's error is pushed onto its neighbours, `0..1`.
  ///
  /// Full strength is the textbook Floyd-Steinberg. Backing it off trades a
  /// little average accuracy for noticeably less speckle, which matters here
  /// because a dithered map is made of 1x1 blocks that the eye reads
  /// individually.
  final double ditherStrength;

  /// Which colour difference to minimise.
  ///
  /// [ColorMetric.cie76] is the default. CIEDE2000 is available and does pick
  /// more appropriate hues for some mid-tone colours, but on a real
  /// illustration it cost roughly forty times as much and did not look better —
  /// see `tool/palette_lab.dart`.
  final ColorMetric metric;

  /// Colour error below which a pixel is left alone rather than dithered.
  ///
  /// Dithering every pixel produces a speckle across the whole picture,
  /// including regions the palette already reproduces well. Restricting it to
  /// pixels that are genuinely far from any map colour keeps flat areas clean
  /// and concentrates the texture where it is buying something.
  ///
  /// "Far from any map colour" is measured on the **source** pixel, and a pixel
  /// inside the threshold takes its own best colour and drops the error it was
  /// carrying. Both halves matter: measuring the error-shifted target instead
  /// lets error from a neighbouring mismatched region keep re-triggering the
  /// diffusion, and a flat white area next to a badly served blue then stipples
  /// from edge to edge even though white is in the palette exactly.
  ///
  /// Diffusion fades in between [ditherThreshold] and twice that value, and it
  /// fades in by **density** — the share of pixels that take part, chosen by a
  /// fixed mask — rather than by strength, so there is no seam at the boundary.
  /// Scaling the diffused error by the ramp instead was tried and is wrong: it
  /// leaves a region both textured *and* the wrong colour, because error
  /// diffusion corrects an average only when the whole error is carried. See
  /// `_ditherMask`.
  ///
  /// The default of 8 was chosen by eye on a real illustration: it leaves flat
  /// regions genuinely flat and still lands within about 2.6 CIE76 of the
  /// original after blurring, against 5.9 for no dithering at all. Every
  /// dithered pixel is an extra block to place, so this also keeps the build
  /// manageable.
  final double ditherThreshold;

  /// Maximum drift, in blocks, that the dither may accumulate within a column.
  ///
  /// Dithering pins every pixel's shade, and the shade decides whether the
  /// surface steps up, stays level, or steps down. Left alone the walk is
  /// essentially random and grows with the square root of the image height,
  /// which puts a 5x5 build hundreds of blocks past the world ceiling — see
  /// `tool/benchmark.dart`.
  ///
  /// Capping it keeps the build inside a known height at the cost of some local
  /// colour accuracy near the cap. The cap is on the drift from the reference
  /// row, so the whole build spans at most `2 * driftBudget + 1` layers.
  ///
  /// `null` leaves it unbounded, which is only sensible for a single map.
  final int? driftBudget;

  /// Keep at most this many blocks, the ones that serve the most pixels.
  ///
  /// `null` keeps every block. One picture does not need 300 kinds of block:
  /// dropping the ones that only ever appear a handful of times makes the
  /// build far easier to shop for and place, and removes some of the dither's
  /// single-pixel speckle, at some cost in colour. Implemented as two passes —
  /// match, count, re-match against the winners — because which blocks matter
  /// is not knowable before matching.
  final int? maxBlocks;

  /// Penalty on a candidate that is *more* colourful than a near-neutral
  /// target, as `(candidateChroma - targetChroma)^2` times this weight.
  ///
  /// [ColorMetric.chromaWeighted] only penalises candidates that are *less*
  /// colourful, which is what keeps a pale cyan from landing on grey. This is
  /// the other half, added to test whether it fixes the cyan cast on white.
  ///
  /// **Measured, and it does not.** For a pure white target the candidates are:
  ///
  /// | block | chroma | ΔE to white | blue − red |
  /// | --- | --- | --- | --- |
  /// | `snow_block` `#f9fefe` | 1.74 | 1.88 | +5 |
  /// | `pearlescent_froglight` `#f6f1f1` | 1.77 | 4.82 | −5 |
  /// | `white_wool` `#eaeded` | 1.06 | 6.56 | +3 |
  /// | `smooth_quartz` `#ede6e0` | 3.99 | 9.23 | −13 |
  ///
  /// `snow_block` is not a high-chroma block — its cast is 1.88 ΔE — while
  /// every more neutral white is 3 to 5 times further away in lightness.
  /// Overturning that needs a weight above 20, which would distort every other
  /// colour. Weights 1 and 3 were tried and the pick never changes. A penalty
  /// on `(blue − red)` in RGB was also worked out and cannot flip it either:
  /// the 16 points of penalty difference do not cover a 39.5 distance gap.
  ///
  /// The cast is really the *threshold* suppressing the dither that would
  /// average it out: at `ditherThreshold` 0 a pure white area renders
  /// `#f7f7f7`, blue − red 0, by mixing `pearlescent_froglight` with
  /// `snow_block`. So the trade is a cyan cast against a checkerboard, not one
  /// block against another. Kept at zero, and offered only so the measurement
  /// can be repeated (`tool/white_probe.dart`).
  final double neutralChromaWeight;

  /// Target chroma below which [neutralChromaWeight] applies.
  ///
  /// Only near-neutral targets are affected, so a deliberately colourful area
  /// still matches exactly as before.
  final double neutralChromaBelow;
}

/// A height plan that keeps a build inside [version]'s world.
///
/// [driftBudget] is the largest drift that still fits: the build spans at most
/// `2 * driftBudget + 1` layers including the reference row. [baseHeight] then
/// centres that span in the usable part of the world, so a build that uses the
/// full budget still clears the ceiling and the floor.
///
/// When the picture is small enough that its natural walk is already shorter
/// than the budget, neither number binds and the build simply sits where it
/// lands.
({int driftBudget, int baseHeight}) suggestHeightPlan(
  MinecraftVersion version, {
  int margin = 20,
}) {
  final usable = version.maxY - version.minY + 1 - margin;
  final driftBudget = ((usable - 1) ~/ 2).clamp(8, 4096);
  final span = 2 * driftBudget + 1;
  final slack = usable - span;
  final baseHeight = version.minY + margin ~/ 2 + slack ~/ 2;
  return (driftBudget: driftBudget, baseHeight: baseHeight);
}

/// Distance used to rank candidates. Squared for CIE76 so the inner loop skips
/// a square root; both are monotonic in closeness, so the winner is the same.
///
/// [targetChroma] and [candidateChroma] are only consulted by
/// [ColorMetric.chromaWeighted]; passing them precomputed keeps the inner loop
/// free of square roots.
double _rankDistance(
  Lab target,
  Lab candidate,
  ColorMetric metric, {
  double targetChroma = 0,
  double candidateChroma = 0,
  OkLab? targetOk,
  OkLab? candidateOk,
  double neutralWeight = 0,
  double neutralBelow = 8,
}) {
  if (metric == ColorMetric.ciede2000) return target.ciede2000To(candidate);
  if (metric == ColorMetric.oklab) {
    return targetOk!.distanceSquaredTo(candidateOk!);
  }
  final dl = target.l - candidate.l;
  final da = target.a - candidate.a;
  final db = target.b - candidate.b;
  var ranked = dl * dl + da * da + db * db;
  if (metric == ColorMetric.chromaWeighted) {
    final deficit = targetChroma - candidateChroma;
    if (deficit > 0) ranked += deficit * deficit;
  }
  // The other direction, and only for near-neutral targets: stop a white from
  // being served by the palette's one slightly-cyan white. See
  // [QuantizeOptions.neutralChromaWeight].
  if (neutralWeight > 0 && target.chroma < neutralBelow) {
    final excess = candidateChroma - target.chroma;
    if (excess > 0) ranked += neutralWeight * excess * excess;
  }
  return ranked;
}

/// Turns the ranking distance into the CIE76 figure stored in the cost table,
/// so costs stay comparable whatever metric produced them.
///
/// For [ColorMetric.chromaWeighted] the reported figure includes the chroma
/// penalty — it is no longer a pure ΔE, but it stays a consistent "how badly
/// did this pixel miss" measure, which is all the dither threshold and the
/// solver's flatness trade-off need.
double _reportedCost(double ranked, ColorMetric metric) =>
    metric == ColorMetric.ciede2000 ? ranked : math.sqrt(ranked);

/// The figure written into the cost table.
///
/// OkLab distances are not on the CIE76 scale the dither threshold and the
/// flatness weight were tuned against, so that metric stores the CIE76 of the
/// colour it actually picked. Everything else stores its own ranking distance,
/// unsquared.
double _storedCost(double ranked, ColorMetric metric, Lab target, Lab chosen) =>
    metric == ColorMetric.oklab
    ? target.distanceTo(chosen)
    : _reportedCost(ranked, metric);

/// Cost assigned to a shade tier that this pixel must not use.
///
/// Used by dithering to pin the solver to the tier the dither chose. Finite
/// rather than infinite so arithmetic on it stays well behaved.
const double blockedTierCost = 1e9;

/// The result of matching every pixel to a base colour and a shade.
///
/// Held as three tiers' worth of flat arrays rather than one array of records:
/// the height solver walks a single column at a time and wants
/// `cost[tier][pixel]` to be a contiguous read.
@immutable
class QuantizedImage {
  QuantizedImage({
    required this.width,
    required this.height,
    required this.choiceIndices,
    required this.choiceCosts,
    required this.dithered,
  }) : assert(choiceIndices.length == ShadeTier.staircase.length),
       assert(choiceCosts.length == ShadeTier.staircase.length);

  final int width;
  final int height;

  /// `choiceIndices[tier][y * width + x]` is the index into `Palette.entries`
  /// of the best block for that pixel at that tier.
  final List<Int32List> choiceIndices;

  /// `choiceCosts[tier][y * width + x]` is the CIE76 distance for that choice,
  /// or [blockedTierCost] when the tier is unavailable.
  final List<Float32List> choiceCosts;

  /// Whether every pixel's shade was pinned.
  ///
  /// Floyd-Steinberg does this, and the height solver then has to walk the
  /// column greedily: the flatness search would otherwise force shades the
  /// dither forbade. The halftone does not set it. Only the pixels it mixes
  /// are pinned, and the rest stay free for the flatness solver.
  final bool dithered;

  int get pixelCount => width * height;

  int paletteIndexAt(ShadeTier tier, int x, int y) =>
      choiceIndices[tier.index][y * width + x];

  double costAt(ShadeTier tier, int x, int y) =>
      choiceCosts[tier.index][y * width + x];

  /// Total CIE76 error of the unconstrained (per-pixel best) choice. Handy for
  /// showing the user how much the dither is buying.
  double get totalBestCost {
    var total = 0.0;
    for (var k = 0; k < choiceCosts.length; k++) {
      final costs = choiceCosts[k];
      for (var p = 0; p < costs.length; p++) {
        final c = costs[p];
        if (c < blockedTierCost) {
          // Only the per-pixel minimum matters, so this over-counts; kept as a
          // cheap relative indicator rather than an exact figure.
          total += c;
        }
      }
    }
    return total;
  }
}

/// Matches every pixel of [source] to the nearest (base colour, shade) pair
/// available in [palette].
///
/// [source] must already be on the map pixel grid — see `fitToGrid`.
QuantizedImage quantize({
  required RgbaImage source,
  required Palette palette,
  QuantizeOptions options = const QuantizeOptions(),
}) {
  if (palette.length == 0) {
    throw ArgumentError('palette has no colours enabled');
  }

  final opaque = source.isOpaque
      ? source
      : source.compositeOnto(options.background);
  final width = opaque.width;
  final height = opaque.height;
  final pixelCount = width * height;

  final tiers = ShadeTier.staircase;
  final tierCount = tiers.length;

  // Precompute the Lab value of every palette entry at every tier. This is the
  // whole point of doing the work up front: the inner loop then only does
  // subtractions.
  final choiceIndices = List<Int32List>.generate(
    tierCount,
    (_) => Int32List(pixelCount),
    growable: false,
  );
  final choiceCosts = List<Float32List>.generate(
    tierCount,
    (_) => Float32List(pixelCount),
    growable: false,
  );

  /// Matches every pixel against [target], writing the flat result arrays.
  ///
  /// A function rather than inline because "at most N blocks" runs the whole
  /// match twice: once to learn which blocks are doing the work, once against
  /// the survivors.
  void match(Palette target) {
    final paletteLab = List<List<Lab>>.generate(target.length, (i) {
      final entry = target.entries[i];
      return List<Lab>.generate(tierCount, (k) {
        final tone = entry.tone(tiers[k]);
        return Lab.fromRgb(tone.r, tone.g, tone.b);
      }, growable: false);
    }, growable: false);

    // Chroma of every tone, precomputed for ColorMetric.chromaWeighted so the
    // inner loop does no square roots.
    final paletteChroma = List<List<double>>.generate(
      target.length,
      (i) => List<double>.generate(
        tierCount,
        (k) => paletteLab[i][k].chroma,
        growable: false,
      ),
      growable: false,
    );

    // Only OkLab ranking needs this. Built from the same tones as [paletteLab]
    // so a tier index lines up.
    final paletteOk = options.metric == ColorMetric.oklab
        ? List<List<OkLab>>.generate(target.length, (i) {
            final entry = target.entries[i];
            return List<OkLab>.generate(tierCount, (k) {
              final tone = entry.tone(tiers[k]);
              return OkLab.fromRgb(tone.r, tone.g, tone.b);
            }, growable: false);
          }, growable: false)
        : null;

    switch (options.dither) {
      case DitherMode.none:
        _quantizeIndependently(
          opaque: opaque,
          paletteLab: paletteLab,
          paletteChroma: paletteChroma,
          paletteOk: paletteOk,
          choiceIndices: choiceIndices,
          choiceCosts: choiceCosts,
          pixelCount: pixelCount,
          tierCount: tierCount,
          flat: target.ignoresShade,
          metric: options.metric,
          neutralWeight: options.neutralChromaWeight,
          neutralBelow: options.neutralChromaBelow,
        );
      case DitherMode.halftone:
        _quantizeIndependently(
          opaque: opaque,
          paletteLab: paletteLab,
          paletteChroma: paletteChroma,
          paletteOk: paletteOk,
          choiceIndices: choiceIndices,
          choiceCosts: choiceCosts,
          pixelCount: pixelCount,
          tierCount: tierCount,
          flat: target.ignoresShade,
          metric: options.metric,
          neutralWeight: options.neutralChromaWeight,
          neutralBelow: options.neutralChromaBelow,
        );
        _halftone(
          opaque: opaque,
          palette: target,
          choiceIndices: choiceIndices,
          choiceCosts: choiceCosts,
          width: width,
          height: height,
          tierCount: tierCount,
          threshold: options.ditherThreshold,
        );
      case DitherMode.floydSteinberg:
        _quantizeWithErrorDiffusion(
          opaque: opaque,
          paletteLab: paletteLab,
          paletteChroma: paletteChroma,
          paletteOk: paletteOk,
          choiceIndices: choiceIndices,
          choiceCosts: choiceCosts,
          width: width,
          height: height,
          tierCount: tierCount,
          strength: options.ditherStrength,
          threshold: options.ditherThreshold,
          flat: target.ignoresShade,
          metric: options.metric,
          neutralWeight: options.neutralChromaWeight,
          neutralBelow: options.neutralChromaBelow,
          driftBudget: options.driftBudget,
        );
    }
  }

  final cap = options.maxBlocks;
  if (cap == null || cap >= palette.length) {
    match(palette);
  } else {
    // Pass one: find out which blocks are doing the work, on a decimated copy
    // of the picture. The ranking only needs each block's rough share, and a
    // 1/16 sample answers that for a sixteenth of the cost. Counting pixels of
    // a full pass would save nothing, because the full pass is the expensive
    // part, not the counting.
    final probe = quantize(
      source: _decimate(opaque, 4),
      palette: palette,
      options: QuantizeOptions(
        dither: options.dither,
        background: options.background,
        ditherStrength: options.ditherStrength,
        metric: options.metric,
        ditherThreshold: options.ditherThreshold,
        neutralChromaWeight: options.neutralChromaWeight,
        neutralChromaBelow: options.neutralChromaBelow,
      ),
    );
    final counts = Int32List(palette.length);
    for (var p = 0; p < probe.pixelCount; p++) {
      var best = double.infinity;
      var bestIndex = 0;
      for (var k = 0; k < tierCount; k++) {
        final cost = probe.choiceCosts[k][p];
        if (cost < best) {
          best = cost;
          bestIndex = probe.choiceIndices[k][p];
        }
      }
      if (best < blockedTierCost) counts[bestIndex]++;
    }
    // Ties go to the lower entry index, which is the representative block of
    // its colour, so a capped palette stays stable across runs.
    final order = List<int>.generate(palette.length, (i) => i)
      ..sort((a, b) {
        final byCount = counts[b].compareTo(counts[a]);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    // Pass two: re-match against the survivors. Dropping a block hands its
    // pixels to the next best, which is why the cap has to be re-matched
    // rather than merely filtered out of the result.
    // Sorted ascending because `onlyIndices` keeps entries in their original
    // order, so subset index `j` is `kept[j]`.
    final kept = order.take(cap).toList()..sort();
    match(palette.onlyIndices(kept.toSet()));
    // The second pass numbered its candidates from zero against the subset, so
    // every index has to go back to the original palette. Without this the
    // caller renders the survivors' colours under the full palette's names,
    // which is silently wrong rather than an error.
    for (var k = 0; k < tierCount; k++) {
      final row = choiceIndices[k];
      for (var p = 0; p < pixelCount; p++) {
        row[p] = kept[row[p]];
      }
    }
  }

  return QuantizedImage(
    width: width,
    height: height,
    choiceIndices: choiceIndices,
    choiceCosts: choiceCosts,
    dithered: options.dither == DitherMode.floydSteinberg,
  );
}

void _quantizeIndependently({
  required RgbaImage opaque,
  required List<List<Lab>> paletteLab,
  required List<List<double>> paletteChroma,
  required List<List<OkLab>>? paletteOk,
  required List<Int32List> choiceIndices,
  required List<Float32List> choiceCosts,
  required int pixelCount,
  required int tierCount,
  required bool flat,
  required ColorMetric metric,
  required double neutralWeight,
  required double neutralBelow,
}) {
  final bytes = opaque.bytes;
  final useOk = metric == ColorMetric.oklab;
  for (var p = 0; p < pixelCount; p++) {
    final o = p * 4;
    final target = Lab.fromRgb(bytes[o], bytes[o + 1], bytes[o + 2]);
    final targetOk = useOk
        ? OkLab.fromRgb(bytes[o], bytes[o + 1], bytes[o + 2])
        : null;
    final targetChroma = metric == ColorMetric.chromaWeighted
        ? target.chroma
        : 0.0;

    for (var k = 0; k < tierCount; k++) {
      // A texture average is the same colour at every shade. Searching the
      // three tiers repeats the same comparison; one pass at normal, with the
      // other two blocked, keeps the build flat.
      if (flat && k != ShadeTier.normal.index) continue;
      var bestRanked = double.infinity;
      var bestIndex = 0;
      for (var i = 0; i < paletteLab.length; i++) {
        final ranked = _rankDistance(
          target,
          paletteLab[i][k],
          metric,
          targetChroma: targetChroma,
          candidateChroma: paletteChroma[i][k],
          targetOk: targetOk,
          candidateOk: useOk ? paletteOk![i][k] : null,
          neutralWeight: neutralWeight,
          neutralBelow: neutralBelow,
        );
        if (ranked < bestRanked) {
          bestRanked = ranked;
          bestIndex = i;
        }
      }
      choiceIndices[k][p] = bestIndex;
      choiceCosts[k][p] = _storedCost(
        bestRanked,
        metric,
        target,
        paletteLab[bestIndex][k],
      );
    }
    if (flat) {
      final normal = ShadeTier.normal.index;
      for (var k = 0; k < tierCount; k++) {
        if (k == normal) continue;
        choiceIndices[k][p] = choiceIndices[normal][p];
        choiceCosts[k][p] = blockedTierCost;
      }
    }
  }
}

/// A copy of [image] sampled every [stride] pixels, for a cheap first pass.
///
/// Nearest-neighbour rather than a filter: this is only used to rank blocks by
/// how much of the picture they serve, and a filter would blur across the very
/// edges that decide it.
RgbaImage _decimate(RgbaImage image, int stride) {
  final width = (image.width / stride).ceil();
  final height = (image.height / stride).ceil();
  final out = RgbaImage(width, height);
  for (var y = 0; y < height; y++) {
    final sy = math.min(y * stride, image.height - 1);
    for (var x = 0; x < width; x++) {
      final sx = math.min(x * stride, image.width - 1);
      out.setRgb(x, y, image.pixelAt(sx, sy));
    }
  }
  return out;
}

/// A palette colour at [ShadeTier.normal], the only shade the halftone uses.
///
/// Several blocks can share one map colour. The first entry wins, which is the
/// representative block, so the mix does not care which concrete block a
/// colour is built from.
class _NormalTone {
  _NormalTone(this.index, this.color)
    : lab = Lab.fromRgb(color.r, color.g, color.b),
      linR = _linearChannel(color.r),
      linG = _linearChannel(color.g),
      linB = _linearChannel(color.b);

  final int index;
  final Rgb color;
  final Lab lab;
  final double linR;
  final double linG;
  final double linB;

  double get chroma => lab.chroma;

  /// Hue in degrees, `0..360`. Neutral colours have no meaningful hue.
  double get hue {
    final degrees = math.atan2(lab.b, lab.a) * 180 / math.pi;
    return degrees < 0 ? degrees + 360 : degrees;
  }
}

/// Replaces pixels the palette cannot match with a two-colour blue-noise mix,
/// both colours at the normal shade.
///
/// The independent match has already been written. A pixel inside
/// [threshold] is left as it is, so a colour the palette already has stays a
/// flat fill and keeps all three shades for the height solver. Past that, the
/// same density ramp as Floyd-Steinberg decides how many pixels take part.
///
/// A pixel that does take part is the mix of the nearest neutral and the
/// nearest same-hue colour, in linear light. Greys are not mixed: their error
/// is lightness, which the three shades already express, and pinning them
/// would throw that away. A chromatic pixel with no same-hue partner is left
/// alone too — a mix with the wrong hue is just confetti.
void _halftone({
  required RgbaImage opaque,
  required Palette palette,
  required List<Int32List> choiceIndices,
  required List<Float32List> choiceCosts,
  required int width,
  required int height,
  required int tierCount,
  required double threshold,
}) {
  final tones = <_NormalTone>[];
  final seen = <int>{};
  for (var i = 0; i < palette.length; i++) {
    final color = palette.entries[i].tone(ShadeTier.normal);
    final key = (color.r << 16) | (color.g << 8) | color.b;
    if (!seen.add(key)) continue;
    tones.add(_NormalTone(i, color));
  }
  if (tones.isEmpty) return;

  final neutrals = tones.where((t) => t.chroma < 8).toList(growable: false);
  final paperPool = neutrals.isEmpty ? tones : neutrals;
  final bytes = opaque.bytes;
  final normal = ShadeTier.normal.index;

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final p = y * width + x;
      var own = double.infinity;
      for (var k = 0; k < tierCount; k++) {
        final cost = choiceCosts[k][p];
        if (cost < own) own = cost;
      }
      if (!_halftoneParticipates(own, threshold, x, y)) continue;

      final o = p * 4;
      final target = Lab.fromRgb(bytes[o], bytes[o + 1], bytes[o + 2]);
      // Lightness error belongs to the shade ladder, not to a dot pattern.
      if (target.chroma < 8) continue;

      final paper = _nearestTone(target, paperPool);
      final ink = _sameHueInk(target, tones);
      if (ink == null || ink.index == paper.index) continue;

      final fraction = _mixFraction(
        Rgb(bytes[o], bytes[o + 1], bytes[o + 2]),
        paper,
        ink,
      );
      // Essentially one of the two colours already. Leave the shade free.
      if (fraction < 0.08 || fraction > 0.92) continue;

      // A second phase of the same matrix, so the density decision and the
      // ink decision are not the same cell.
      final chosen = _ditherMask(x + 3, y + 5) < fraction ? ink : paper;
      final cost = target.distanceTo(chosen.lab);
      for (var k = 0; k < tierCount; k++) {
        choiceIndices[k][p] = chosen.index;
        choiceCosts[k][p] = k == normal ? cost : blockedTierCost;
      }
    }
  }
}

/// Whether [own] — the pixel's best single-colour error — is far enough, and
/// this cell of the blue-noise ramp is one of the pixels that takes part.
bool _halftoneParticipates(double own, double threshold, int x, int y) {
  if (threshold <= 0) return true;
  final ramp = ((own - threshold) / threshold).clamp(0.0, 1.0);
  if (ramp == 0) return false;
  return ramp >= _ditherMask(x, y);
}

_NormalTone _nearestTone(Lab target, List<_NormalTone> tones) {
  var best = tones.first;
  var bestD = double.infinity;
  for (final tone in tones) {
    final d = target.distanceTo(tone.lab);
    if (d < bestD) {
      bestD = d;
      best = tone;
    }
  }
  return best;
}

/// The chromatic tone whose hue is closest to [target], or null when nothing
/// colourful sits within 40° of it.
_NormalTone? _sameHueInk(Lab target, List<_NormalTone> tones) {
  final hue = _hueDegrees(target);
  _NormalTone? best;
  var bestHue = double.infinity;
  var bestD = double.infinity;
  for (final tone in tones) {
    if (tone.chroma <= 15) continue;
    final hueDist = _circularHue(tone.hue, hue);
    if (hueDist >= 40) continue;
    final d = target.distanceTo(tone.lab);
    if (hueDist < bestHue || (hueDist == bestHue && d < bestD)) {
      bestHue = hueDist;
      bestD = d;
      best = tone;
    }
  }
  return best;
}

double _hueDegrees(Lab lab) {
  final degrees = math.atan2(lab.b, lab.a) * 180 / math.pi;
  return degrees < 0 ? degrees + 360 : degrees;
}

double _circularHue(double a, double b) {
  final d = (a - b).abs();
  return d > 180 ? 360 - d : d;
}

/// Fraction of [ink] in a linear-light mix that lands closest to [target].
///
/// Searched in twentieths. The halftone only needs the ratio, not a
/// continuous blend, and twenty steps is finer than an 8x8 mask can show.
double _mixFraction(Rgb target, _NormalTone paper, _NormalTone ink) {
  final want = Lab.fromRgb(target.r, target.g, target.b);
  var bestT = 0.0;
  var bestD = double.infinity;
  for (var i = 0; i <= 20; i++) {
    final t = i / 20.0;
    final mixed = Lab.fromRgb(
      _fromLinear(paper.linR + (ink.linR - paper.linR) * t),
      _fromLinear(paper.linG + (ink.linG - paper.linG) * t),
      _fromLinear(paper.linB + (ink.linB - paper.linB) * t),
    );
    final d = want.distanceTo(mixed);
    if (d < bestD) {
      bestD = d;
      bestT = t;
    }
  }
  return bestT;
}

double _linearChannel(int channel) {
  final x = channel / 255.0;
  return x <= 0.04045
      ? x / 12.92
      : math.pow((x + 0.055) / 1.055, 2.4).toDouble();
}

int _fromLinear(double linear) {
  final s = linear <= 0.0031308
      ? 12.92 * linear
      : 1.055 * math.pow(linear, 1 / 2.4) - 0.055;
  final scaled = (s * 255).round();
  if (scaled < 0) return 0;
  if (scaled > 255) return 255;
  return scaled;
}

void _quantizeWithErrorDiffusion({
  required RgbaImage opaque,
  required List<List<Lab>> paletteLab,
  required List<List<double>> paletteChroma,
  required List<List<OkLab>>? paletteOk,
  required List<Int32List> choiceIndices,
  required List<Float32List> choiceCosts,
  required int width,
  required int height,
  required int tierCount,
  required double strength,
  required double threshold,
  required bool flat,
  required ColorMetric metric,
  required double neutralWeight,
  required double neutralBelow,
  required int? driftBudget,
}) {
  // Carried error, in Lab, three channels per pixel.
  final error = Float32List(width * height * 3);
  final bytes = opaque.bytes;

  // Running height offset per column, in the same units the height solver uses:
  // the tier chosen for a pixel decides whether the surface steps up, stays
  // level, or steps down. Tracking it here is what lets the dither respect a
  // height budget instead of walking off to wherever the error happens to push
  // it.
  final columnOffset = Int32List(width);

  // Bounding box of what the palette can actually reach. Without clamping to
  // it, a region brighter than the brightest available colour — pure white, say
  // — accumulates error forever and dithers itself into a speckled mess even
  // though no improvement is possible.
  var minL = double.infinity, maxL = -double.infinity;
  var minA = double.infinity, maxA = -double.infinity;
  var minB = double.infinity, maxB = -double.infinity;
  for (final perTier in paletteLab) {
    for (final lab in perTier) {
      if (lab.l < minL) minL = lab.l;
      if (lab.l > maxL) maxL = lab.l;
      if (lab.a < minA) minA = lab.a;
      if (lab.a > maxA) maxA = lab.a;
      if (lab.b < minB) minB = lab.b;
      if (lab.b > maxB) maxB = lab.b;
    }
  }

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final p = y * width + x;
      final o = p * 4;
      final base = Lab.fromRgb(bytes[o], bytes[o + 1], bytes[o + 2]);
      final e = p * 3;
      final adjusted = Lab(
        base.l + error[e],
        base.a + error[e + 1],
        base.b + error[e + 2],
      );
      // Clamp to the reachable box before matching, and diffuse the error
      // relative to the clamped target. That is what stops out-of-gamut
      // regions from dithering against a wall.
      //
      // Note the box is the whole palette's, so it barely bites. Capping the
      // *carried error* was tried as a way to stop the occasional pixel that
      // error diffusion lands on a colour unrelated to the source, and it is
      // the wrong tool: on a uniform colour the palette cannot reach, capping
      // the error stops the accumulation that the mixing depends on, and the
      // result is not a dithered approximation but one flat wrong colour
      // (`tool/budget_probe.dart` measures the span going to zero). The
      // accumulation is the mechanism, not a bug in it.
      final target = Lab(
        adjusted.l.clamp(minL, maxL),
        adjusted.a.clamp(minA, maxA),
        adjusted.b.clamp(minB, maxB),
      );
      // The carried error lives in CIE Lab. OkLab ranking has to see that
      // shifted colour, so it goes back through sRGB. With no error yet the
      // source pixel's OkLab is exact and the round-trip is skipped.
      final useOk = paletteOk != null;
      final OkLab? baseOk;
      final OkLab? targetOk;
      if (!useOk) {
        baseOk = null;
        targetOk = null;
      } else if (error[e] == 0 && error[e + 1] == 0 && error[e + 2] == 0) {
        baseOk = OkLab.fromRgb(bytes[o], bytes[o + 1], bytes[o + 2]);
        targetOk = baseOk;
      } else {
        baseOk = OkLab.fromRgb(bytes[o], bytes[o + 1], bytes[o + 2]);
        final shifted = target.toRgb();
        targetOk = OkLab.fromRgb(shifted[0], shifted[1], shifted[2]);
      }

      // Tiers the drift budget still allows for this column. When the budget is
      // about to be exceeded the choice is narrowed to the tiers that move back
      // towards the reference row, which costs some colour accuracy at the
      // extreme but keeps the build buildable.
      var allowBright = true;
      var allowNormal = true;
      var allowDark = true;
      if (driftBudget != null) {
        final current = columnOffset[x];
        allowBright = (current + 1).abs() <= driftBudget;
        allowNormal = current.abs() <= driftBudget;
        allowDark = (current - 1).abs() <= driftBudget;
        if (!allowBright && !allowNormal && !allowDark) {
          // Should not happen for a budget of at least one, but never leave the
          // pixel without a legal choice.
          allowNormal = true;
        }
      }

      var bestRanked = double.infinity;
      var bestIndex = 0;
      var bestTier = 0;

      // The same search run against the *unshifted* pixel, used only to decide
      // whether this pixel should be dithered at all. Judging that on `target`
      // instead — which is what this used to do — measures how far the carried
      // error has drifted rather than how far the picture is from the palette,
      // so error arriving from a mismatched neighbour re-arms the diffusion at
      // every pixel it reaches and a flat area next to a bad one stipples from
      // edge to edge. Skipped entirely when the threshold is off, because then
      // every pixel is dithered and there is nothing to decide.
      final trackOwn = threshold > 0;
      var ownRanked = double.infinity;
      var ownIndex = 0;
      var ownTier = 0;

      final targetChroma = metric == ColorMetric.chromaWeighted
          ? target.chroma
          : 0.0;
      final baseChroma = metric == ColorMetric.chromaWeighted && trackOwn
          ? base.chroma
          : 0.0;

      for (var i = 0; i < paletteLab.length; i++) {
        for (var k = 0; k < tierCount; k++) {
          final allowed = switch (ShadeTier.staircase[k]) {
            ShadeTier.bright => allowBright,
            ShadeTier.normal => allowNormal,
            _ => allowDark,
          };
          if (!allowed) continue;
          if (flat && ShadeTier.staircase[k] != ShadeTier.normal) continue;
          final ranked = _rankDistance(
            target,
            paletteLab[i][k],
            metric,
            targetChroma: targetChroma,
            candidateChroma: paletteChroma[i][k],
            targetOk: targetOk,
            candidateOk: useOk ? paletteOk[i][k] : null,
          );
          if (ranked < bestRanked ||
              (ranked == bestRanked &&
                  ShadeTier.staircase[k] == ShadeTier.normal &&
                  ShadeTier.staircase[bestTier] != ShadeTier.normal)) {
            bestRanked = ranked;
            bestIndex = i;
            bestTier = k;
          }
          if (trackOwn) {
            final own = _rankDistance(
              base,
              paletteLab[i][k],
              metric,
              targetChroma: baseChroma,
              candidateChroma: paletteChroma[i][k],
              targetOk: baseOk,
              candidateOk: useOk ? paletteOk[i][k] : null,
              neutralWeight: neutralWeight,
              neutralBelow: neutralBelow,
            );
            if (own < ownRanked ||
                (own == ownRanked &&
                    ShadeTier.staircase[k] == ShadeTier.normal &&
                    ShadeTier.staircase[ownTier] != ShadeTier.normal)) {
              ownRanked = own;
              ownIndex = i;
              ownTier = k;
            }
          }
        }
      }

      // A pixel the palette already reaches to within the threshold is left
      // alone: it takes its own best colour, and the error it was carrying is
      // dropped rather than passed on. That is the whole point of the threshold
      // — the region is already close enough, and stippling it to chase the
      // last few ΔE is what makes a flat wall of white look like noise.
      var paintIndex = bestIndex;
      var paintTier = bestTier;
      var paintRanked = bestRanked;
      var dither = true;
      var carry = true;
      if (trackOwn) {
        // How badly this pixel missed, from 0 at the threshold to 1 at twice
        // it. Used as the *density* of the dither, not its strength.
        final ownCost = useOk
            ? base.distanceTo(paletteLab[ownIndex][ownTier])
            : _reportedCost(ownRanked, metric);
        final ramp = ((ownCost - threshold) / threshold).clamp(0.0, 1.0);
        if (ramp == 0) {
          // Inside the threshold: this pixel is already right. Paint it flat
          // and stop here — the error it was carrying is dropped, so error
          // from a neighbouring region the palette cannot reach cannot leak in
          // and stipple a region the palette reproduces exactly.
          paintIndex = ownIndex;
          paintTier = ownTier;
          paintRanked = ownRanked;
          dither = false;
          carry = false;
        } else {
          // Beyond the threshold the region does need the dither, and the mask
          // decides how many of its pixels take part. Those that do not still
          // *pass the error on* rather than dropping it: the region's average
          // is only corrected if the whole error survives to be spent, and
          // dropping it here is what left a region at 1.35x the threshold both
          // textured and the wrong colour.
          dither = ramp >= _ditherMask(x, y);
          if (!dither) {
            paintIndex = ownIndex;
            paintTier = ownTier;
            paintRanked = ownRanked;
          }
        }
      }

      columnOffset[x] += ShadeTier.staircase[paintTier].heightDelta;

      // Pin the solver to the dithered tier; the other two are unavailable.
      for (var k = 0; k < tierCount; k++) {
        choiceIndices[k][p] = paintIndex;
        choiceCosts[k][p] = k == paintTier
            ? _storedCost(
                paintRanked,
                metric,
                base,
                paletteLab[paintIndex][paintTier],
              )
            : blockedTierCost;
      }

      if (carry) {
        final chosen = paletteLab[paintIndex][paintTier];
        // Full strength whenever the residual is carried at all.
        //
        // Scaling the diffusion by how badly the pixel missed — which is what
        // this used to do — reads as the obvious way to fade the dither in, and
        // it is wrong: error diffusion corrects a region's average *because*
        // the whole error is carried, so carrying a fraction of it leaves the
        // region both textured and wrongly coloured. The fade belongs in how
        // *many* pixels take part, which is what the mask above does.
        _diffuse(
          error,
          width,
          height,
          x,
          y,
          Lab(
            (target.l - chosen.l) * strength,
            (target.a - chosen.a) * strength,
            (target.b - chosen.b) * strength,
          ),
        );
      }
    }
  }
}

/// Where the dither's density ramp switches each pixel on or off.
///
/// An 8x8 blue-noise matrix, in `(0, 1)`. A pixel dithers when the ramp — 0 at
/// the threshold, 1 at twice it — reaches its cell's value, so a region at
/// ramp 0.35 dithers 35% of its pixels and a region at ramp 1 dithers all of
/// them.
///
/// This exists because fading the dither in by scaling the *diffused error* is
/// not the same thing as fading it in, and looks it: it leaves the region
/// textured and still the wrong colour, and it puts a visible seam wherever the
/// ramp changes, because a flat region and a 35%-strength dither of the same
/// colour read completely differently. Ramping the density instead keeps every
/// dithering pixel at full strength — so the region's average is actually
/// corrected — and turns the seam into a gradient of texture, which is what the
/// eye expects.
///
/// Blue noise rather than a Bayer matrix: at mid-ramp a Bayer matrix selects a
/// perfect checkerboard, which is the single most visible binary pattern there
/// is — a pale region at ramp 0.5 becomes a regular grid of dots that reads as
/// a printing defect rather than shading. A void-and-cluster matrix keeps the
/// same density at every ramp value but distributes the dots as far apart as
/// possible instead of on a lattice, so the texture reads as grain rather than
/// as a grid.
double _ditherMask(int x, int y) => _blueNoise8[(y & 7) * 8 + (x & 7)];

/// `(rank + 0.5) / 64` of a void-and-cluster ranking, so the range is
/// `(0.0078, 0.992)` and a ramp of 1 turns every cell on while a ramp of 0
/// turns every one off.
///
/// Generated deterministically with Ulichney's void-and-cluster: start from a
/// few random points, rank them tightest-cluster-first out, then fill the
/// remaining ranks largest-void-first, where "cluster" and "void" are measured
/// by a gaussian over wrap-around distances on the 8x8 torus. 64 cells is
/// cheap enough that doing this at startup beats hard-coding a table nobody
/// can audit.
final Float64List _blueNoise8 = () {
  const n = 8;
  const count = n * n;
  const sigma = 1.5;
  const twoSigmaSq = 2 * sigma * sigma;

  double energy(int x, int y, List<bool> on) {
    var e = 0.0;
    for (var yy = 0; yy < n; yy++) {
      for (var xx = 0; xx < n; xx++) {
        if (!on[yy * n + xx] || (xx == x && yy == y)) continue;
        var dx = (xx - x).abs();
        if (dx > n - dx) dx = n - dx;
        var dy = (yy - y).abs();
        if (dy > n - dy) dy = n - dy;
        e += math.exp(-(dx * dx + dy * dy) / twoSigmaSq);
      }
    }
    return e;
  }

  final rng = math.Random(0x5EED);
  final on = List<bool>.filled(count, false);
  final rank = Int32List(count);

  var ones = 0;
  while (ones < count ~/ 8) {
    final i = rng.nextInt(count);
    if (!on[i]) {
      on[i] = true;
      ones++;
    }
  }

  // Rank the seed points out, tightest cluster first, taking the top ranks.
  var nextRank = count - 1;
  while (ones > 0) {
    var bestI = -1;
    var bestE = -1.0;
    for (var i = 0; i < count; i++) {
      if (!on[i]) continue;
      final e = energy(i % n, i ~/ n, on);
      if (e > bestE) {
        bestE = e;
        bestI = i;
      }
    }
    rank[bestI] = nextRank--;
    on[bestI] = false;
    ones--;
  }

  // Fill the remaining ranks, largest void first.
  while (nextRank >= 0) {
    var bestI = -1;
    var bestE = double.infinity;
    for (var i = 0; i < count; i++) {
      if (on[i]) continue;
      final e = energy(i % n, i ~/ n, on);
      if (e < bestE) {
        bestE = e;
        bestI = i;
      }
    }
    rank[bestI] = nextRank--;
    on[bestI] = true;
  }

  final out = Float64List(count);
  for (var i = 0; i < count; i++) {
    out[i] = (rank[i] + 0.5) / count;
  }
  return out;
}();

/// Standard Floyd-Steinberg weights, scanned north to south and west to east so
/// that the height solver can still walk the image in its natural direction.
void _diffuse(
  Float32List error,
  int width,
  int height,
  int x,
  int y,
  Lab delta,
) {
  void add(int dx, int dy, double weight) {
    final nx = x + dx;
    final ny = y + dy;
    if (nx < 0 || nx >= width || ny >= height) return;
    final p = (ny * width + nx) * 3;
    error[p] += delta.l * weight;
    error[p + 1] += delta.a * weight;
    error[p + 2] += delta.b * weight;
  }

  add(1, 0, 7 / 16);
  add(-1, 1, 3 / 16);
  add(0, 1, 5 / 16);
  add(1, 1, 1 / 16);
}
