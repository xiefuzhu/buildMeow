import 'package:mapart_core/mapart_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late ColorTable table;
  late Palette palette;

  setUpAll(() {
    table = loadColorTable();
    palette = Palette.select(table, '1.20');
  });

  group('solver and renderer are inverses', () {
    test('a flat colour reproduces exactly', () {
      final pipeline = Pipeline.run(
        gradient(64, 64),
        palette: palette,
        mapsX: 1,
        mapsY: 1,
      );
      expect(
        pipeline.rendered.bytes,
        pipeline.requested.bytes,
        reason: 'the rendered map must match what quantization asked for',
      );
      expect(
        countMismatchedPixels(
          solution: pipeline.solution,
          quantized: pipeline.quantized,
          palette: palette,
        ),
        0,
      );
    });

    test('a noisy image reproduces exactly', () {
      final pipeline = Pipeline.run(
        noiseImage(200, 200),
        palette: palette,
        mapsX: 1,
        mapsY: 1,
      );
      expect(pipeline.rendered.bytes, pipeline.requested.bytes);
    });

    test('every palette colour and tier survives the round trip', () {
      // Sweep a dense set of colours through the full pipeline one pixel at a
      // time, so nothing is hidden by a large image averaging things out.
      final failures = <String>[];
      for (final entry in palette.entries) {
        for (final tier in ShadeTier.staircase) {
          final tone = entry.tone(tier);
          final pipeline = Pipeline.run(
            _solid(4, 4, tone),
            palette: palette,
            mapsX: 1,
            mapsY: 1,
          );
          final rendered = pipeline.rendered.pixelAt(0, 0);
          if (rendered != tone) {
            failures.add('${entry.name} $tier ($tone) rendered as $rendered');
          }
        }
      }
      expect(failures, isEmpty, reason: failures.take(10).join('\n'));
    });

    test('Water is the one colour that cannot be built', () {
      // Colour 10 has no full solid cube candidate upstream, so it is absent
      // from the palette and its shades are unreachable. Asserted here so the
      // limitation stays visible instead of being quietly swept up.
      expect(palette.unavailableColorIndices, <int>[10]);
      expect(palette.forColor(10), isNull);

      final water = table[10];
      final rendered = Pipeline.run(
        _solid(4, 4, water.baseColor),
        palette: palette,
        mapsX: 1,
        mapsY: 1,
      ).rendered.pixelAt(0, 0);
      expect(
        rendered,
        isNot(water.baseColor),
        reason: 'Water blue is not reproducible with a full solid cube',
      );
    });

    test('the rendered shade matches the solved height relationship', () {
      final pipeline = Pipeline.run(
        gradient(128, 128),
        palette: palette,
        mapsX: 1,
        mapsY: 1,
      );

      for (var y = 0; y < 128; y++) {
        for (var x = 0; x < 128; x++) {
          final height = pipeline.solution.heightAt(x, y);
          final north = y == 0
              ? pipeline.solution.referenceRowHeight
              : pipeline.solution.heightAt(x, y - 1);
          final expected = ShadeTier.fromHeightDelta(height - north);
          expect(
            pipeline.solution.tierAt(x, y),
            expected,
            reason: 'at $x,$y',
          );
        }
      }
    });

    test('a dithered map also reproduces exactly', () {
      final pipeline = Pipeline.run(
        gradient(96, 96),
        palette: palette,
        mapsX: 1,
        mapsY: 1,
        dither: DitherMode.floydSteinberg,
      );
      expect(pipeline.quantized.dithered, isTrue);
      expect(
        pipeline.rendered.bytes,
        pipeline.requested.bytes,
        reason: 'dithering pins the shade, so it must come out exactly',
      );
    });
  });

  group('staircase validity', () {
    test('every step is -1, 0 or +1 across a full-size image', () {
      final pipeline = Pipeline.run(
        noiseImage(128, 128),
        palette: palette,
        mapsX: 1,
        mapsY: 1,
      );
      for (var x = 0; x < 128; x++) {
        for (var y = 1; y < 128; y++) {
          final delta =
              pipeline.solution.heightAt(x, y) -
              pipeline.solution.heightAt(x, y - 1);
          expect(delta, inInclusiveRange(-1, 1), reason: 'at $x,$y');
        }
      }
    });

    test('the north-most row is within one block of the reference row', () {
      final pipeline = Pipeline.run(
        noiseImage(128, 128),
        palette: palette,
        mapsX: 1,
        mapsY: 1,
      );
      for (var x = 0; x < 128; x++) {
        final delta =
            pipeline.solution.heightAt(x, 0) -
            pipeline.solution.referenceRowHeight;
        expect(delta, inInclusiveRange(-1, 1), reason: 'column $x');
      }
    });

    test('flatness pressure still produces a legal staircase', () {
      final pipeline = Pipeline.run(
        noiseImage(64, 64),
        palette: palette,
        mapsX: 1,
        mapsY: 1,
        heights: const HeightSolverOptions(
          flatnessWeight: 5,
          freeDrift: 8,
        ),
      );
      for (var x = 0; x < 64; x++) {
        for (var y = 1; y < 64; y++) {
          final delta =
              pipeline.solution.heightAt(x, y) -
              pipeline.solution.heightAt(x, y - 1);
          expect(delta, inInclusiveRange(-1, 1), reason: 'at $x,$y');
        }
      }
    });
  });

  group('multi-map continuity', () {
    test('heights are solved across the whole image, not per map tile', () {
      // The same content laid out as one map and as two maps side by side must
      // give the same heights, because the shift is global. A per-tile solve
      // would reset the surface at the tile boundary.
      final single = Pipeline.run(
        noiseImage(128, 128, seed: 11),
        palette: palette,
        mapsX: 1,
        mapsY: 1,
      );
      final double = Pipeline.run(
        _tileHorizontally(noiseImage(128, 128, seed: 11)),
        palette: palette,
        mapsX: 2,
        mapsY: 1,
      );

      // Both halves of the two-map solve should match the single-map solve,
      // after accounting for the shared global shift.
      final singleMin = single.solution.minHeight;
      final doubleMin = double.solution.minHeight;
      expect(doubleMin, single.solution.minHeight);

      for (var y = 0; y < 128; y++) {
        for (var x = 0; x < 128; x++) {
          final left = double.solution.heightAt(x, y) - doubleMin;
          final expected = single.solution.heightAt(x, y) - singleMin;
          expect(left, expected, reason: 'left half at $x,$y');
          final right = double.solution.heightAt(x + 128, y) - doubleMin;
          expect(right, expected, reason: 'right half at $x,$y');
        }
      }
    });

    test('a two-map build spans exactly twice the width', () {
      final pipeline = Pipeline.run(
        gradient(256, 128),
        palette: palette,
        mapsX: 2,
        mapsY: 1,
        cropMode: CropMode.cover,
      );
      expect(pipeline.solution.width, 256);
      expect(pipeline.solution.height, 128);
    });
  });

  group('pipeline output', () {
    test('rendered size matches the requested map grid', () {
      final pipeline = Pipeline.run(
        gradient(300, 200),
        palette: palette,
        mapsX: 2,
        mapsY: 2,
      );
      expect(pipeline.rendered.width, 256);
      expect(pipeline.rendered.height, 256);
      expect(pipeline.rendered.isOpaque, isTrue);
    });

    test('contain mode keeps the background colour visible', () {
      final pipeline = Pipeline.run(
        _solid(64, 32, const Rgb(255, 0, 0)),
        palette: palette,
        mapsX: 1,
        mapsY: 1,
        cropMode: CropMode.contain,
      );
      // The top band is padding, so it must have matched the white background
      // rather than the red image.
      final topBand = pipeline.rendered.pixelAt(64, 0);
      final middle = pipeline.rendered.pixelAt(64, 64);
      expect(topBand, isNot(middle));
      expect(middle.r, greaterThan(middle.b));
    });
  });
}

RgbaImage _solid(int width, int height, Rgb color) {
  final image = RgbaImage(width, height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setRgb(x, y, color);
    }
  }
  return image;
}

RgbaImage _tileHorizontally(RgbaImage image) {
  final out = RgbaImage(image.width * 2, image.height);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final p = image.pixelAt(x, y);
      out.setRgb(x, y, p);
      out.setRgb(x + image.width, y, p);
    }
  }
  return out;
}
