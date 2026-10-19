import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:mapart_core/mapart_core.dart';
import 'package:meta/meta.dart';

/// Everything the pipeline needs to run.
///
/// Plain data only, because this crosses an isolate boundary. The colour and
/// version tables are passed in rather than re-read from assets: `rootBundle`
/// is not available in a background isolate without extra plumbing, and the
/// tables are small.
@immutable
class PipelineRequest {
  const PipelineRequest({
    required this.encodedImage,
    required this.colorTable,
    required this.versionTable,
    required this.versionId,
    required this.mapsX,
    required this.mapsY,
    required this.cropMode,
    required this.dither,
    required this.ditherThreshold,
    required this.metric,
    required this.driftBudget,
    required this.background,
    required this.disabledBlockKeys,
    required this.includeSupportBlocks,
    this.artKind = ArtKind.mapItem,
    this.flatMap = false,
    this.productionPalette,
    this.blockNames = BlockNames.empty,
    this.ditherStrength = 1.0,
    this.maxBlocks,
    this.blockColors = const {},
    this.textureAtlas,
    this.textureIndex = const {},
    this.textureCell = 16,
    required this.flatnessWeight,
    required this.baseHeight,
  });

  /// The image file's bytes, still encoded. Decoding is CPU work and belongs in
  /// the isolate with everything else.
  final Uint8List encodedImage;
  final ArtKind artKind;
  final bool flatMap;
  final Palette? productionPalette;

  final ColorTable colorTable;
  final VersionTable versionTable;
  final String versionId;

  final int mapsX;
  final int mapsY;
  final CropMode cropMode;

  final DitherMode dither;
  final double ditherThreshold;

  /// How much of each pixel's dither error is pushed onto its neighbours,
  /// `0..1`. Lower is less speckle and less average accuracy.
  final double ditherStrength;

  /// Keep at most this many blocks. `null` keeps every block.
  final int? maxBlocks;

  /// Which colour difference the matcher minimises.
  final ColorMetric metric;

  /// `null` leaves the dither's height walk unbounded.
  final int? driftBudget;

  final Rgb background;

  /// Blocks the user switched off, as `PaletteEntry.key`. Quantization only
  /// sees the rest.
  final Set<String> disabledBlockKeys;

  /// Chinese names for the blocks, so the plan can label them. Empty is
  /// legitimate: the plan falls back to the English name.
  final BlockNames blockNames;

  /// Whether blocks that need something underneath them — slabs, carpets,
  /// sand — are offered as well. Off by default: a staircase is built from full
  /// solid cubes.
  final bool includeSupportBlocks;

  /// Per-block colours, packed `0xRRGGBB` and keyed by block id. Empty leaves
  /// every block on the shared map colour.
  final Map<String, int> blockColors;

  /// Packed face textures, or null to preview each block as a flat colour.
  final Uint8List? textureAtlas;

  /// Block id to cell index in [textureAtlas].
  final Map<String, int> textureIndex;

  /// Texels on one side of a cell in [textureAtlas].
  final int textureCell;

  final double flatnessWeight;
  final int baseHeight;
}

/// What the pipeline produced, ready to display.
@immutable
class PipelineResult {
  const PipelineResult({
    required this.plan,
    this.previewCell = 16,
    required this.rendered,
    required this.preview,
    required this.target,
    required this.textured,
    required this.mapsX,
    required this.mapsY,
    required this.minHeight,
    required this.maxHeight,
    required this.referenceRowHeight,
    required this.blockHeightSpan,
    required this.warnings,
    required this.fitsWorld,
    required this.elapsed,
    required this.paletteColours,
    required this.paletteBlocks,
    required this.ditheredPixels,
    required this.blocksUsed,
    required this.top20Coverage,
    required this.top40Coverage,
    required this.pixelMeanError,
    required this.blurredMeanError,
  });

  /// The picture as data: which block sits where, at what height, and how many
  /// of each. Everything past the preview — the material list, the blueprint
  /// viewer, the PDF/PNG/CSV sheets and the schematic writers — reads this
  /// rather than the solver's internals.
  final MapPlan plan;
  ArtKind get artKind => plan.artKind;
  final int previewCell;

  /// What Minecraft's map will show, one pixel per block.
  final RgbaImage rendered;

  /// The same map with each block drawn as its face texture. This is what the
  /// preview shows.
  final RgbaImage preview;

  /// The source resampled onto the map grid, i.e. what the pipeline was trying
  /// to reproduce. Shown side by side so the loss is visible rather than
  /// claimed.
  final RgbaImage target;

  /// Whether [preview] has each block drawn as its face texture, which is the
  /// case only when the palette is built from texture averages. Hiding a block
  /// needs to know: re-rendering a textured preview needs the atlas, and a
  /// flat one does not.
  final bool textured;

  final int mapsX;
  final int mapsY;

  final int minHeight;
  final int maxHeight;
  final int referenceRowHeight;

  /// Total layers the build spans, reference row included.
  final int blockHeightSpan;

  final List<String> warnings;
  final bool fitsWorld;
  final Duration elapsed;

  /// How many distinct base colours the palette could reach after the user's
  /// toggles. This is what decides how many of the 180 staircase map colours
  /// are on the table.
  final int paletteColours;

  /// How many individual blocks were available, i.e. how much choice there was
  /// about what to build each colour out of. Many blocks share a colour, so
  /// this is larger than [paletteColours] and does not change the picture — it
  /// changes the shopping list.
  final int paletteBlocks;

  /// How many pixels the dither had to texture.
  final int ditheredPixels;

  /// How many distinct blocks the finished picture actually uses.
  ///
  /// The shopping list. A palette of 300 that only ever places 90 is a 90-block
  /// build, and this is the number that says so.
  final int blocksUsed;

  /// Share of pixels served by the most-used 20 and 40 blocks, `0..1`.
  ///
  /// Answers "how much would a cap of N cost", which is what decides whether
  /// the "at most N blocks" cap is worth turning on.
  final double top20Coverage;
  final double top40Coverage;

  /// Mean CIE76 error per pixel. Always higher when dithering, which is the
  /// point of dithering, so [blurredMeanError] is the figure to judge by.
  final double pixelMeanError;

  /// Mean CIE76 error after a small blur of both images, which is what the eye
  /// integrates.
  final double blurredMeanError;

  int get width => rendered.width;
  int get height => rendered.height;
}

/// Runs the whole pipeline. Top-level so `Isolate.run` can send it.
PipelineResult executePipeline(
  PipelineRequest request, {
  void Function(String stage, Duration elapsed)? onStage,
}) {
  final watch = Stopwatch()..start();
  var lastStage = Duration.zero;
  void finishStage(String name) {
    if (onStage == null) return;
    final now = watch.elapsed;
    onStage(name, now - lastStage);
    lastStage = now;
  }

  final decoded = img.decodeImage(request.encodedImage);
  if (decoded == null) {
    throw const FormatException('could not decode the image');
  }
  final source = normalizeRgba(decoded).compositeOnto(request.background);
  finishStage('decode');

  final grid = fitToGrid(
    source,
    request.mapsX * 128,
    request.mapsY * 128,
    mode: request.cropMode,
    background: request.background,
  );
  finishStage('resize');

  final candidates =
      request.productionPalette ??
      Palette.blocks(
        request.colorTable,
        request.versionTable.require(request.versionId).blockSetAlias,
        gameVersion: request.versionId,
        includeSupportBlocks: request.includeSupportBlocks,
      ).withBlockColors(
        request.blockColors,
        host: request.colorTable.colors.first,
      );
  final full = request.artKind == ArtKind.mapItem && request.flatMap
      ? candidates.atNormalMapShade()
      : candidates;
  final palette = request.disabledBlockKeys.isEmpty
      ? full
      : full.excludingKeys(request.disabledBlockKeys);
  if (palette.length == 0) {
    throw StateError('every block is switched off');
  }
  finishStage('palette');

  final quantized = quantize(
    source: grid,
    palette: palette,
    options: QuantizeOptions(
      dither: request.dither,
      ditherThreshold: request.ditherThreshold,
      ditherStrength: request.ditherStrength,
      maxBlocks: request.maxBlocks,
      metric: request.metric,
      driftBudget: request.driftBudget,
      background: request.background,
    ),
  );
  finishStage('quantize');

  final solution = solveHeights(
    quantized: quantized,
    version: request.versionTable.require(request.versionId),
    options: HeightSolverOptions(
      baseHeight: request.baseHeight,
      // Dithering pins every shade, so flatness pressure cannot apply and the
      // solver says so in its warnings. Passing zero keeps the two from
      // fighting.
      flatnessWeight: quantized.dithered ? 0 : request.flatnessWeight,
    ),
  );
  finishStage('solveHeights');

  // The picture as data, built once and rendered from: the preview, the
  // material list, the blueprint sheets and the schematic writers all read this
  // one structure, so they cannot disagree about what the build is.
  final plan = buildMapPlan(
    solution: solution,
    quantized: quantized,
    palette: palette,
    version: request.versionTable.require(request.versionId),
    names: request.blockNames,
    artKind: request.artKind,
  );
  finishStage('buildPlan');

  final rendered = renderPlanMap(plan: plan);
  finishStage('renderMap');
  final previewCell = boundedPreviewCell(
    plan.width,
    plan.height,
    request.textureCell,
  );
  final preview = request.textureAtlas == null
      ? rendered
      : renderTexturedPlan(
          plan: plan,
          atlas: decodeAtlasPng(request.textureAtlas!),
          textureIndex: request.textureIndex,
          cell: request.textureCell,
          previewCell: previewCell,
        );
  finishStage('renderPreview');

  var dithered = 0;
  for (var p = 0; p < quantized.pixelCount; p++) {
    for (final tier in ShadeTier.staircase) {
      if (quantized.choiceCosts[tier.index][p] < blockedTierCost) {
        dithered++;
        break;
      }
    }
  }

  // How much of the picture the most-used blocks cover, which is what decides
  // whether the "at most N blocks" cap is worth turning on. The plan already
  // sorts by count, so this is a prefix sum.
  final total = plan.totalBlocks;
  double coverage(int top) {
    var sum = 0;
    for (var i = 0; i < top && i < plan.counts.length; i++) {
      sum += plan.counts[i];
    }
    return sum / total;
  }

  finishStage('statistics');
  final errors = _errors(grid, rendered);
  finishStage('errorMetrics');

  return PipelineResult(
    plan: plan,
    previewCell: previewCell,
    rendered: rendered,
    preview: preview,
    target: grid,
    textured: request.textureAtlas != null,
    mapsX: plan.mapsX,
    mapsY: plan.mapsY,
    minHeight: plan.minHeight,
    maxHeight: plan.maxHeight,
    referenceRowHeight: plan.referenceRowHeight,
    blockHeightSpan: plan.blockHeightSpan,
    warnings: solution.warnings,
    fitsWorld: solution.fitsWorld,
    elapsed: watch.elapsed,
    paletteColours: palette.distinctColorCount,
    paletteBlocks: palette.length,
    ditheredPixels: dithered,
    blocksUsed: plan.blocks.length,
    top20Coverage: coverage(20),
    top40Coverage: coverage(40),
    pixelMeanError: errors.$1,
    blurredMeanError: errors.$2,
  );
}

/// An obsolete computation was explicitly stopped, not a generation failure.
class PipelineCancelled implements Exception {
  const PipelineCancelled();
}

/// Owns one disposable compute isolate. Cancelling also handles a spawn that
/// has not returned yet; completed results still transfer with Isolate.exit.
class PipelineWorker {
  _PipelineTask? _active;

  Future<PipelineResult> run(PipelineRequest request) {
    cancel();
    final task = _PipelineTask(request);
    _active = task;
    return task.result.future.whenComplete(() {
      if (identical(_active, task)) _active = null;
    });
  }

  void cancel() {
    final task = _active;
    _active = null;
    task?.cancel();
  }
}

class _PipelineTask {
  _PipelineTask(PipelineRequest request) {
    _port.listen((message) {
      if (result.isCompleted) return;
      if (message is List && message.length == 1) {
        result.complete(message.single as PipelineResult);
      } else if (message is List && message.length == 2) {
        final stack = message[1];
        result.completeError(
          stack is StackTrace
              ? message[0] as Object
              : RemoteError('${message[0]}', '$stack'),
          stack is StackTrace ? stack : StackTrace.fromString('$stack'),
        );
      } else {
        result.completeError(StateError('生成进程提前结束'));
      }
      _port.close();
    });
    unawaited(_spawn(request));
  }

  final result = Completer<PipelineResult>();
  final _port = ReceivePort();
  Isolate? _isolate;

  Future<void> _spawn(PipelineRequest request) async {
    try {
      final isolate = await Isolate.spawn(
        _pipelineEntry,
        (request, _port.sendPort),
        onError: _port.sendPort,
        onExit: _port.sendPort,
        errorsAreFatal: true,
      );
      if (result.isCompleted) {
        isolate.kill(priority: Isolate.immediate);
      } else {
        _isolate = isolate;
      }
    } on Object catch (error, stack) {
      if (!result.isCompleted) {
        result.completeError(error, stack);
        _port.close();
      }
    }
  }

  void cancel() {
    if (result.isCompleted) return;
    _isolate?.kill(priority: Isolate.immediate);
    _port.close();
    result.completeError(const PipelineCancelled());
  }
}

void _pipelineEntry((PipelineRequest, SendPort) message) {
  try {
    final result = executePipeline(message.$1);
    Isolate.exit(message.$2, [result]);
  } on Object catch (error, stack) {
    Isolate.exit(message.$2, [error, stack]);
  }
}

/// Runs [executePipeline] off the UI thread.
Future<PipelineResult> runPipeline(PipelineRequest request) =>
    PipelineWorker().run(request);

/// Mean CIE76 error, and the same after a 3x3 blur of both images.
(double, double) _errors(RgbaImage target, RgbaImage rendered) {
  var pointwise = 0.0;
  for (var y = 0; y < target.height; y++) {
    for (var x = 0; x < target.width; x++) {
      pointwise += _deltaE(target.pixelAt(x, y), rendered.pixelAt(x, y));
    }
  }
  final count = target.width * target.height;

  final blurredTarget = _blur(target);
  final blurredRendered = _blur(rendered);
  var blurred = 0.0;
  for (var y = 0; y < target.height; y++) {
    for (var x = 0; x < target.width; x++) {
      blurred += _deltaE(
        blurredTarget.pixelAt(x, y),
        blurredRendered.pixelAt(x, y),
      );
    }
  }

  return (pointwise / count, blurred / count);
}

double _deltaE(Rgb a, Rgb b) =>
    Lab.fromRgb(a.r, a.g, a.b).distanceTo(Lab.fromRgb(b.r, b.g, b.b));

RgbaImage _blur(RgbaImage image) {
  final out = RgbaImage(image.width, image.height);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      var r = 0, g = 0, b = 0, n = 0;
      for (var dy = -1; dy <= 1; dy++) {
        final sy = y + dy;
        if (sy < 0 || sy >= image.height) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final sx = x + dx;
          if (sx < 0 || sx >= image.width) continue;
          final p = image.pixelAt(sx, sy);
          r += p.r;
          g += p.g;
          b += p.b;
          n++;
        }
      }
      out.setPixel(x, y, r ~/ n, g ~/ n, b ~/ n);
    }
  }
  return out;
}

/// Turns the packed face-texture atlas into an image the core renderer can
/// sample.
///
/// The atlas ships as a PNG because that is what keeps the app bundle small;
/// core works on plain RGBA buffers so it can run in an isolate, so the decode
/// happens on the way in. Public because hiding a block re-renders the preview
/// from the same bytes without going through the pipeline.
RgbaImage? decodeAtlasPng(Uint8List png) {
  final decoded = img.decodePng(png);
  return decoded == null ? null : normalizeRgba(decoded);
}

/// Preserve palette colours and scale native channel depth instead of wrapping
/// 16-bit samples into bytes. One-channel images carry luminance in r only.
RgbaImage normalizeRgba(img.Image source) {
  final out = RgbaImage(source.width, source.height);
  final grey = !source.hasPalette && source.numChannels <= 2;
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final p = source.getPixel(x, y);
      final scale = 255 / p.maxChannelValue;
      int byte(num value) => (value * scale).round().clamp(0, 255);
      final r = byte(p.r);
      out.setPixel(
        x,
        y,
        r,
        grey ? r : byte(p.g),
        grey ? r : byte(p.b),
        byte(p.a),
      );
    }
  }
  return out;
}

int boundedPreviewCell(int width, int height, int textureCell) =>
    (4096 ~/ (width > height ? width : height)).clamp(1, textureCell);
