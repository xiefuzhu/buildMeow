import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_meow/src/data/pipeline.dart';
import 'package:build_meow/src/state/project.dart';
// `Override` is not in the main export; it lives in `misc.dart`.
import 'package:flutter_riverpod/misc.dart';
import 'package:image/image.dart' as img;
import 'package:mapart_core/mapart_core.dart';

/// A real solve, for the tests that need a plan rather than a hand-made one.
///
/// The pipeline is run for real — the vendored colour table, the vendored
/// Chinese names, the real quantizer — because the pages under test read a
/// `MapPlan` and a plan that never came out of the pipeline would not prove
/// anything about them. It is slow, a second or so, which is why every file
/// builds one in `setUpAll` and shares it.
PipelineResult buildTestResult({int mapsX = 1, int mapsY = 1}) =>
    executePipeline(buildTestRequest(mapsX: mapsX, mapsY: mapsY));

Future<MapPlan> buildTestPlan({int mapsX = 1, int mapsY = 1}) async =>
    buildTestResult(mapsX: mapsX, mapsY: mapsY).plan;

PipelineRequest buildTestRequest({int mapsX = 1, int mapsY = 1}) =>
    PipelineRequest(
      encodedImage: _png(mapsX * 128, mapsY * 128),
      colorTable: _colorTable(),
      versionTable: _versionTable(),
      versionId: VersionTable.defaultVersionId,
      mapsX: mapsX,
      mapsY: mapsY,
      cropMode: CropMode.cover,
      dither: DitherMode.none,
      ditherThreshold: 8,
      metric: ColorMetric.cie76,
      driftBudget: null,
      background: const Rgb(255, 255, 255),
      disabledBlockKeys: const <String>{},
      includeSupportBlocks: false,
      blockNames: _blockNames(),
      flatnessWeight: 5,
      baseHeight: 64,
    );

/// A fixed-result pipeline, so a page can be pumped without a solve.
class FixedPipeline extends PipelineNotifier {
  FixedPipeline(this.result);

  final PipelineResult result;

  @override
  PipelineResult? build() => result;

  @override
  void clear() {}
}

/// The providers every page test needs, with the real tables and a result that
/// is already solved.
List<Override> planOverrides(PipelineResult result) => [
  colorTableProvider.overrideWith((ref) async => _colorTable()),
  versionTableProvider.overrideWith((ref) async => _versionTable()),
  blockColorsProvider.overrideWith((ref) async => const {}),
  blockCapabilitiesProvider.overrideWith(
    (ref) async => const BlockCapabilities({}, {}),
  ),
  blockNamesProvider.overrideWith((ref) async => BlockNames.empty),
  resultProvider.overrideWith(() => FixedPipeline(result)),
];

File _coreAsset(String path) {
  final file = File('../packages/mapart_core/assets/$path');
  if (!file.existsSync()) {
    throw StateError(
      'missing ${file.absolute.path} — run `flutter test` from the app '
      'directory',
    );
  }
  return file;
}

ColorTable _colorTable() => ColorTable.fromJson(
  jsonDecode(_coreAsset('colors/mapartcraft.colors.json').readAsStringSync())
      as Map<String, dynamic>,
);

VersionTable _versionTable() => VersionTable.fromJson(
  jsonDecode(_coreAsset('colors/versions.json').readAsStringSync())
      as Map<String, dynamic>,
);

BlockNames _blockNames() => BlockNames.fromJson(
  jsonDecode(_coreAsset('lang/zh_cn_blocks.json').readAsStringSync())
      as Map<String, dynamic>,
);

/// A picture with hard colour bands, which is what makes a staircase: every
/// band wants its own shade, so the heights have to step.
Uint8List _png(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final band = ((x ~/ 16) + (y ~/ 16)) % 4;
      image.setPixelRgb(
        x,
        y,
        switch (band) {
          0 => 255,
          1 => 200,
          2 => 40,
          _ => 120,
        },
        switch (band) {
          0 => 40,
          1 => 200,
          2 => 255,
          _ => 120,
        },
        90,
      );
    }
  }
  return img.encodePng(image);
}
