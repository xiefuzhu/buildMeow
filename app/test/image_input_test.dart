import 'dart:typed_data';

import 'package:build_meow/src/data/pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mapart_core/mapart_core.dart';

import 'plan_support.dart';

PipelineResult process(Uint8List bytes, {CropMode mode = CropMode.contain}) {
  final base = buildTestRequest();
  return executePipeline(
    PipelineRequest(
      encodedImage: bytes,
      colorTable: base.colorTable,
      versionTable: base.versionTable,
      versionId: base.versionId,
      mapsX: 1,
      mapsY: 1,
      cropMode: mode,
      dither: DitherMode.none,
      ditherThreshold: 8,
      metric: ColorMetric.cie76,
      driftBudget: null,
      background: const Rgb(255, 255, 255),
      disabledBlockKeys: const {},
      includeSupportBlocks: false,
      flatnessWeight: 0,
      baseHeight: 64,
    ),
  );
}

void main() {
  test('one-channel PNG remains grey through the real pipeline', () {
    final image = img.Image(width: 1, height: 1, numChannels: 1);
    image.setPixelRgb(0, 0, 128, 128, 128);
    expect(
      process(img.encodePng(image)).target.pixelAt(64, 64),
      const Rgb(128, 128, 128),
    );
  });
  test('16-bit PNG scales channels to 8-bit instead of wrapping', () {
    final image = img.Image(
      width: 1,
      height: 1,
      numChannels: 3,
      format: img.Format.uint16,
    );
    image.setPixelRgb(0, 0, 32768, 65535, 0);
    expect(
      process(img.encodePng(image)).target.pixelAt(64, 64),
      const Rgb(128, 255, 0),
    );
  });
  test('indexed PNG resolves its palette and alpha', () {
    final image = img.Image(
      width: 1,
      height: 1,
      numChannels: 3,
      withPalette: true,
    );
    image.palette!.setRgb(7, 20, 80, 160);
    image.getPixel(0, 0).index = 7;
    expect(
      process(img.encodePng(image)).target.pixelAt(64, 64),
      const Rgb(20, 80, 160),
    );
  });
  test('grayscale with alpha keeps luminance and transparency', () {
    final image = img.Image(width: 1, height: 1, numChannels: 2);
    image.setPixelRgba(0, 0, 90, 90, 90, 128);
    final out = normalizeRgba(image);
    expect(out.pixelAt(0, 0), const Rgb(90, 90, 90));
    expect(out.alphaAt(0, 0), 128);
  });
  test('invisible blue does not contaminate resampled red edges', () {
    final image = img.Image(width: 2, height: 1, numChannels: 4);
    image.setPixelRgba(0, 0, 255, 0, 0, 255);
    image.setPixelRgba(1, 0, 0, 0, 255, 0);
    final target = process(img.encodePng(image)).target;
    for (var x = 0; x < target.width; x++) {
      final p = target.pixelAt(x, 64);
      expect(p.g, p.b, reason: 'red over white has equal green and blue');
    }
  });
  test('contain retains aspect ratio while cover deliberately crops', () {
    final image = img.Image(width: 16, height: 8, numChannels: 3);
    final bytes = img.encodePng(image);
    final contained = process(bytes).target;
    expect(contained.pixelAt(64, 0), const Rgb(255, 255, 255));
    expect(contained.pixelAt(64, 64), const Rgb(0, 0, 0));
    expect(
      process(bytes, mode: CropMode.cover).target.pixelAt(64, 0),
      const Rgb(0, 0, 0),
    );
  });
  test('JPEG EXIF orientation is applied once', () {
    final image = img.Image(width: 40, height: 20, numChannels: 3);
    for (var y = 0; y < 20; y++) {
      for (var x = 0; x < 40; x++) {
        image.setPixelRgb(x, y, x < 20 ? 240 : 0, x < 20 ? 0 : 240, 0);
      }
    }
    image.exif.imageIfd.orientation = 6;
    final target = process(img.encodeJpg(image, quality: 100)).target;
    expect(target.pixelAt(64, 12).r, greaterThan(200));
    expect(target.pixelAt(64, 116).g, greaterThan(200));
    expect(target.pixelAt(0, 64), const Rgb(255, 255, 255));
  });
  test('downsampled preview uses the original atlas cell offsets', () {
    final plan = buildTestResult().plan;
    final atlas = RgbaImage(8, 4);
    for (var y = 0; y < 4; y++) {
      for (var x = 0; x < 8; x++) {
        atlas.setRgb(x, y, x < 4 ? const Rgb(255, 0, 0) : const Rgb(0, 255, 0));
      }
    }
    final output = renderTexturedPlan(
      plan: plan,
      atlas: atlas,
      cell: 4,
      previewCell: 2,
      textureIndex: {for (final b in plan.blocks) b.blockId: 1},
    );
    expect(output.width, plan.width * 2);
    expect(output.pixelAt(0, 0), const Rgb(0, 255, 0));
    expect(boundedPreviewCell(2048, 2048, 16), 2);
  });
}
