import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_meow/src/data/pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mapart_core/mapart_core.dart';

/// Core's assets live in its own package, so the app's tests read them from
/// disk rather than through `rootBundle`. That keeps the test independent of
/// Flutter's asset plumbing while still exercising the real data.
File _coreAsset(String name) {
  final file = File('../packages/mapart_core/assets/colors/$name');
  if (!file.existsSync()) {
    throw StateError(
      'missing ${file.absolute.path} — run `flutter test` from the app '
      'directory',
    );
  }
  return file;
}

ColorTable _colorTable() => ColorTable.fromJson(
  jsonDecode(_coreAsset('mapartcraft.colors.json').readAsStringSync())
      as Map<String, dynamic>,
);

VersionTable _versionTable() => VersionTable.fromJson(
  jsonDecode(_coreAsset('versions.json').readAsStringSync())
      as Map<String, dynamic>,
);

/// A picture with a smooth gradient, a hard edge and some noise, so the
/// resampler, the colour matcher and the height solver all have work to do.
List<int> _sourcePng() {
  final image = img.Image(width: 300, height: 200, numChannels: 3);
  for (var y = 0; y < 200; y++) {
    for (var x = 0; x < 300; x++) {
      final band = x < 150 ? 40 : 210;
      final shade = (60 * y / 199).round();
      image.setPixelRgb(
        x,
        y,
        (band + shade).clamp(0, 255),
        (band ~/ 2 + shade).clamp(0, 255),
        (255 - band + shade ~/ 2).clamp(0, 255),
      );
    }
  }
  return img.encodePng(image);
}

PipelineRequest _request({
  DitherMode dither = DitherMode.none,
  int mapsX = 1,
  int mapsY = 1,
  Set<String> disabledKeys = const <String>{},
  bool includeSupportBlocks = false,
  CropMode cropMode = CropMode.cover,
  Uint8List? encodedImage,
}) {
  final versions = _versionTable();
  const versionId = '26.1.2';
  final plan = suggestHeightPlan(versions.require(versionId));
  return PipelineRequest(
    encodedImage: encodedImage ?? Uint8List.fromList(_sourcePng()),
    colorTable: _colorTable(),
    versionTable: versions,
    versionId: versionId,
    mapsX: mapsX,
    mapsY: mapsY,
    cropMode: cropMode,
    dither: dither,
    ditherThreshold: 8,
    metric: ColorMetric.cie76,
    driftBudget: dither == DitherMode.none ? null : plan.driftBudget,
    background: const Rgb(255, 255, 255),
    disabledBlockKeys: disabledKeys,
    includeSupportBlocks: includeSupportBlocks,
    flatnessWeight: 5,
    baseHeight: plan.baseHeight,
  );
}

/// Every block key the palette offers for the `1.20` block set.
Set<String> _allKeys({bool includeSupportBlocks = false}) => {
  for (final entry in Palette.blocks(
    _colorTable(),
    '1.20',
    includeSupportBlocks: includeSupportBlocks,
  ).entries)
    entry.key,
};

/// Every block of the listed colours, i.e. what "switch this colour off" means
/// now that the palette is per block.
Set<String> _allKeysOf(Iterable<int> colorIndices) {
  final palette = Palette.blocks(_colorTable(), '1.20');
  return {
    for (final colorIndex in colorIndices)
      for (final entry in palette.entriesForColor(colorIndex)) entry.key,
  };
}

void main() {
  group('PipelineWorker', () {
    test('cancelling during spawn completes and allows another run', () async {
      final worker = PipelineWorker();
      addTearDown(worker.cancel);
      final pending = worker.run(_request(mapsX: 16, mapsY: 16));
      final cancelled = expectLater(pending, throwsA(isA<PipelineCancelled>()));
      worker.cancel();
      await cancelled.timeout(const Duration(seconds: 2));
      final result = await worker.run(_request());
      expect(result.width, 128);
      expect(result.fitsWorld, isTrue);
    });

    test(
      'a running large solve stops without waiting for completion',
      () async {
        final worker = PipelineWorker();
        addTearDown(worker.cancel);
        final pending = worker.run(
          _request(mapsX: 16, mapsY: 16, dither: DitherMode.floydSteinberg),
        );
        final cancelled = expectLater(
          pending,
          throwsA(isA<PipelineCancelled>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        worker.cancel();
        await cancelled.timeout(const Duration(seconds: 2));
        worker.cancel();
      },
    );

    test('worker output matches synchronous output', () async {
      final request = _request();
      final expected = executePipeline(request);
      final actual = await runPipeline(request);
      expect(actual.rendered.bytes, expected.rendered.bytes);
      expect(actual.plan.counts, expected.plan.counts);
      expect(actual.pixelMeanError, expected.pixelMeanError);
    });

    test('worker reports decode errors and remains reusable', () async {
      final worker = PipelineWorker();
      addTearDown(worker.cancel);
      await expectLater(
        worker.run(_request(encodedImage: Uint8List(0))),
        throwsA(isA<FormatException>()),
      );
      expect((await worker.run(_request())).width, 128);
    });
  });

  group('executePipeline', () {
    test(
      'stage measurements preserve output and account for pipeline time',
      () {
        final request = _request();
        final baseline = executePipeline(request);
        final timings = <String, Duration>{};
        final measured = executePipeline(
          request,
          onStage: (stage, elapsed) => timings[stage] = elapsed,
        );
        expect(timings.keys, [
          'decode',
          'resize',
          'palette',
          'quantize',
          'solveHeights',
          'buildPlan',
          'renderMap',
          'renderPreview',
          'statistics',
          'errorMetrics',
        ]);
        expect(
          timings.values,
          everyElement(greaterThanOrEqualTo(Duration.zero)),
        );
        final accounted = timings.values.fold(
          Duration.zero,
          (total, elapsed) => total + elapsed,
        );
        expect(accounted, lessThanOrEqualTo(measured.elapsed));
        expect(
          measured.elapsed - accounted,
          lessThan(const Duration(seconds: 1)),
        );
        expect(measured.rendered.bytes, baseline.rendered.bytes);
        expect(measured.preview.bytes, baseline.preview.bytes);
        expect(measured.pixelMeanError, baseline.pixelMeanError);
        expect(measured.blurredMeanError, baseline.blurredMeanError);
        expect(measured.plan.counts, baseline.plan.counts);
      },
    );

    test('produces a map grid of the requested size', () {
      final result = executePipeline(_request(mapsX: 2, mapsY: 1));
      expect(result.width, 256);
      expect(result.height, 128);
      expect(result.mapsX, 2);
      expect(result.rendered.isOpaque, isTrue);
      expect(result.target.width, 256);
    });

    test('the build fits the world it was planned for', () {
      final result = executePipeline(_request());
      expect(result.fitsWorld, isTrue);
      expect(result.blockHeightSpan, lessThanOrEqualTo(384));
      expect(result.referenceRowHeight, isNot(0));
    });

    test('a larger build still fits, because the budget binds', () {
      // Without a drift budget the dither's walk for a 3x3 build overshoots the
      // overworld by hundreds of layers.
      final result = executePipeline(
        _request(mapsX: 3, mapsY: 3, dither: DitherMode.floydSteinberg),
      );
      expect(result.width, 384);
      expect(result.fitsWorld, isTrue, reason: result.warnings.join('; '));
      expect(result.blockHeightSpan, lessThanOrEqualTo(384));
    });

    test('dithering lowers the error the eye sees', () {
      final plain = executePipeline(_request());
      final dithered = executePipeline(
        _request(dither: DitherMode.floydSteinberg),
      );

      expect(dithered.ditheredPixels, greaterThan(0));
      // What the eye integrates is the figure that matters, and it must go
      // down. The per-pixel figure is deliberately not asserted: dithering
      // usually raises it, but when a picture is already close to the palette
      // the diffusion can nudge targets onto reachable colours and lower it
      // too. Either way the blurred number is the one that describes what you
      // see.
      expect(dithered.blurredMeanError, lessThan(plain.blurredMeanError));
    });

    test('switching colours off shrinks the palette', () {
      final full = executePipeline(_request());
      final off = _allKeysOf(<int>[0, 13, 28, 30]);
      final reduced = executePipeline(_request(disabledKeys: off));
      expect(reduced.paletteColours, full.paletteColours - 4);
      expect(reduced.paletteBlocks, full.paletteBlocks - off.length);
      // The per-pixel error must go up: every pixel picks the nearest entry
      // from a strictly smaller set, so its best possible choice can only get
      // worse. The blurred figure is not monotone in the same way — a locally
      // worse choice can blur into a better neighbourhood average — so it is
      // the per-pixel number that is asserted here.
      expect(reduced.pixelMeanError, greaterThanOrEqualTo(full.pixelMeanError));
    });

    test('the palette offers a block per colour, not one per colour', () {
      final result = executePipeline(_request());
      // 60 usable base colours, 209 full solid cubes between them: the colour
      // count is fixed by the game, the block count is the choice.
      expect(result.paletteColours, 60);
      expect(result.paletteBlocks, 209);
    });

    test('expanding the palette to every block leaves the picture alone', () {
      // The expanded palette must quantize to exactly the same image as the
      // one-block-per-colour palette it replaces. It does because the entry
      // `select` would have picked is listed first within its colour and
      // `quantize` breaks a tie on the lowest entry index, so the extra entries
      // are only ever reached when the user switches the earlier ones off.
      final table = _colorTable();
      final representatives = {
        for (final entry in Palette.select(table, '1.20').entries) entry.key,
      };
      final onlyRepresentatives = _allKeys()..removeAll(representatives);

      final every = executePipeline(_request());
      final oneEach = executePipeline(
        _request(disabledKeys: onlyRepresentatives),
      );

      expect(every.paletteBlocks, 209);
      expect(oneEach.paletteBlocks, representatives.length);
      expect(oneEach.paletteColours, every.paletteColours);
      expect(oneEach.blockHeightSpan, every.blockHeightSpan);
      expect(oneEach.rendered.bytes, every.rendered.bytes);
    });

    test('admitting the support-requiring blocks reaches Water', () {
      final plain = executePipeline(_request());
      final withSupport = executePipeline(_request(includeSupportBlocks: true));
      expect(plain.paletteColours, 60);
      expect(withSupport.paletteColours, 61);
      expect(withSupport.paletteBlocks, 323);
    });

    test('switching everything off is rejected, not rendered', () {
      expect(
        () => executePipeline(_request(disabledKeys: _allKeys())),
        throwsA(isA<StateError>()),
      );
    });

    test('contain mode pads with the background', () {
      final result = executePipeline(_request(cropMode: CropMode.contain));
      // The source is 3:2, the grid is square, so bands appear top and bottom
      // and must have matched the white background rather than the picture.
      final topBand = result.rendered.pixelAt(64, 0);
      expect(topBand.r, greaterThan(200));
      expect(topBand.g, greaterThan(200));
      expect(topBand.b, greaterThan(200));
    });

    test('garbage input is reported rather than silently empty', () {
      final request = _request();
      expect(
        () => executePipeline(
          PipelineRequest(
            encodedImage: Uint8List.fromList(const [1, 2, 3, 4, 5]),
            colorTable: request.colorTable,
            versionTable: request.versionTable,
            versionId: request.versionId,
            mapsX: 1,
            mapsY: 1,
            cropMode: CropMode.cover,
            dither: DitherMode.none,
            ditherThreshold: 8,
            metric: ColorMetric.cie76,
            driftBudget: null,
            background: const Rgb(255, 255, 255),
            disabledBlockKeys: const <String>{},
            includeSupportBlocks: false,
            flatnessWeight: 5,
            baseHeight: 0,
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
