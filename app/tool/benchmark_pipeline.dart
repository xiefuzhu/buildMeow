// Run from app/ after compiling with:
// dart compile exe tool/benchmark_pipeline.dart -o build/benchmark_pipeline.exe
// build/benchmark_pipeline.exe --sizes=1,5,16 --output=build/benchmarks/pipeline.json
// Each case uses a fresh process. RSS is process-wide (including setup), not
// Dart heap usage; stage timings exclude asset reads and source PNG creation.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:mapart_core/mapart_core.dart';

import 'package:build_meow/src/data/pipeline.dart';

const _stages = [
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
];

Future<void> main(List<String> args) async {
  try {
    final options = <String, String>{};
    const allowed = {
      'sizes',
      'kinds',
      'dithers',
      'metrics',
      'timeout-seconds',
      'output',
      'case',
    };
    for (final arg in args) {
      final split = arg.indexOf('=');
      if (!arg.startsWith('--') || split < 3) {
        throw FormatException('Expected --name=value, got $arg');
      }
      final key = arg.substring(2, split);
      if (!allowed.contains(key)) throw FormatException('Unknown option: $key');
      options[key] = arg.substring(split + 1);
    }
    if (options.containsKey('case')) {
      stdout.writeln(jsonEncode(_runCase(options['case']!)));
      return;
    }
    final sizes = (options['sizes'] ?? '1,5,16')
        .split(',')
        .map(int.parse)
        .toList();
    if (sizes.any((size) => size < 1 || size > 16)) {
      throw const FormatException('Sizes must be between 1 and 16');
    }
    final kinds = _select(options['kinds'], ArtKind.values);
    final dithers = _select(
      options['dithers'] ?? 'none,floydSteinberg',
      DitherMode.values,
    );
    final metrics = _select(
      options['metrics'] ?? 'cie76,chromaWeighted,ciede2000',
      ColorMetric.values,
    );
    final timeout = int.parse(options['timeout-seconds'] ?? '120');
    if (timeout <= 0) throw const FormatException('Timeout must be positive');
    final output = File(options['output'] ?? 'build/benchmarks/pipeline.json');
    final report = <String, Object?>{
      'schemaVersion': 1,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'runtime': Platform.version,
      'os': Platform.operatingSystem,
      'processors': Platform.numberOfProcessors,
      'executable': Platform.resolvedExecutable,
      'measurement':
          'Fresh process per case; cold run; process peak RSS includes '
          'asset loading and fixture creation; pipeline stages exclude setup and '
          'UI/isolate transfer. Not an end-to-end Flutter benchmark.',
      'source':
          'Deterministic 2048x2048 RGB gradient, hard edge and seeded noise',
      'timeoutSeconds': timeout,
      'cases': <Map<String, Object?>>[],
    };
    final results = report['cases'] as List<Map<String, Object?>>;
    Future<void> saveReport() async {
      await output.parent.create(recursive: true);
      await output.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
    }

    await saveReport();
    for (final size in sizes) {
      for (final kind in kinds) {
        for (final dither in dithers) {
          for (final metric in metrics) {
            final id = '$size/${kind.name}/${dither.name}/${metric.name}';
            stdout.writeln('START $id');
            final result = await _measureCase(id, timeout);
            results.add(result);
            await saveReport();
            stdout.writeln(
              '${result['status']} $id '
              'pipelineMs=${result['pipelineMs']} peakRssBytes=${result['peakRssBytes']}',
            );
          }
        }
      }
    }
    report['finishedAt'] = DateTime.now().toUtc().toIso8601String();
    await saveReport();
    stdout.writeln('Report: ${output.path}');
    if (results.any((result) => result['status'] != 'ok')) exitCode = 1;
  } on Object catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exitCode = 1;
  }
}

List<T> _select<T extends Enum>(String? raw, List<T> values) {
  if (raw == null) return values;
  return raw.split(',').map((name) {
    return values.firstWhere(
      (value) => value.name == name,
      orElse: () => throw FormatException('Unknown choice: $name'),
    );
  }).toList();
}

Future<Map<String, Object?>> _measureCase(String id, int timeoutSeconds) async {
  // Passing the script path also supports a quick JIT smoke run; the report
  // records the runtime/executable so JIT and AOT data are not conflated.
  final executable = Platform.resolvedExecutable;
  final isDart = RegExp(
    r'[/\\]dart(?:\.exe)?$',
    caseSensitive: false,
  ).hasMatch(executable);
  final process = await Process.start(executable, [
    if (isDart) Platform.script.toFilePath(),
    '--case=$id',
  ]);
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  var timedOut = false;
  final timer = Timer(Duration(seconds: timeoutSeconds), () {
    timedOut = true;
    process.kill();
  });
  final code = await process.exitCode;
  timer.cancel();
  final text = await output;
  final errorText = await errors;
  if (timedOut || code != 0) {
    return {
      'id': id,
      'status': timedOut ? 'timeout' : 'failed',
      'exitCode': code,
      'stderr': errorText,
    };
  }
  try {
    return jsonDecode(text) as Map<String, dynamic>;
  } on FormatException catch (error) {
    return {'id': id, 'status': 'failed', 'stderr': '$error\n$errorText'};
  }
}

Map<String, dynamic> _asset(String name) =>
    jsonDecode(File('../packages/mapart_core/assets/$name').readAsStringSync())
        as Map<String, dynamic>;

Map<String, Object?> _runCase(String id) {
  final parts = id.split('/');
  final size = int.parse(parts[0]);
  final kind = ArtKind.values.byName(parts[1]);
  final dither = DitherMode.values.byName(parts[2]);
  final metric = ColorMetric.values.byName(parts[3]);
  if (size < 1 || size > 16) throw const FormatException('Invalid case size');
  final table = ColorTable.fromJson(_asset('colors/mapartcraft.colors.json'))
      .includingGameBlocks(_asset('colors/block_map_colors.json'), '26.1.2');
  final versions = VersionTable.fromJson(_asset('colors/versions.json'));
  final version = versions.require('26.1.2');
  final keptFile = File(
    '../packages/mapart_core/assets/colors/kept_blocks.json',
  );
  final kept = keptFile.existsSync()
      ? (jsonDecode(keptFile.readAsStringSync()) as List).cast<String>().toSet()
      : <String>{};
  final colors = blockColoursFromTexturePalette(
    _asset('colors/texture_palette_26_1_2.json'),
    keep: kept,
  );
  final atlas = _asset('colors/block_textures.json');
  final atlasIndex =
      (atlas['blocks'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, (value as num).toInt()),
      )..removeWhere(
        (key, _) =>
            key.contains('glass') ||
            key == 'beacon' ||
            (kept.isNotEmpty && !kept.contains(key)),
      );
  final capabilities = BlockCapabilities.fromJson(
    _asset('colors/block_capabilities.json'),
  );
  final palette = resolveProductionPalette(
    table: table,
    version: version,
    kind: kind,
    blockColors: colors,
    capabilities: capabilities,
  );
  final height = suggestHeightPlan(version);
  final request = PipelineRequest(
    encodedImage: _sourcePng(),
    artKind: kind,
    productionPalette: palette,
    colorTable: table,
    versionTable: versions,
    versionId: version.id,
    mapsX: size,
    mapsY: size,
    cropMode: CropMode.contain,
    dither: dither,
    ditherThreshold: 8,
    metric: metric,
    driftBudget: dither == DitherMode.none ? null : height.driftBudget,
    background: const Rgb(255, 255, 255),
    disabledBlockKeys: const {},
    includeSupportBlocks: false,
    blockNames: BlockNames.fromJson(_asset('lang/zh_cn_blocks.json')),
    blockColors: kind == ArtKind.blockPixels ? colors : const {},
    textureAtlas: kind == ArtKind.blockPixels
        ? File('../packages/mapart_core/assets/colors/block_textures.png')
              .readAsBytesSync()
        : null,
    textureIndex: kind == ArtKind.blockPixels ? atlasIndex : const {},
    textureCell: (atlas['cell'] as num).toInt(),
    flatnessWeight: 5,
    baseHeight: height.baseHeight,
  );
  final rssBefore = ProcessInfo.currentRss;
  final stages = <String, double>{};
  final watch = Stopwatch()..start();
  final result = executePipeline(
    request,
    onStage: (name, elapsed) {
      stages[name] = elapsed.inMicroseconds / 1000;
    },
  );
  final wallMs = watch.elapsedMicroseconds / 1000;
  if (stages.keys.join(',') != _stages.join(',')) {
    throw StateError('Pipeline stage coverage changed');
  }
  return {
    'id': id,
    'status': 'ok',
    'maps': size,
    'kind': kind.name,
    'dither': dither.name,
    'metric': metric.name,
    'pipelineMs': result.elapsed.inMicroseconds / 1000,
    'wallMs': wallMs,
    'stagesMs': stages,
    'rssBeforePipelineBytes': rssBefore,
    'rssAfterPipelineBytes': ProcessInfo.currentRss,
    'peakRssBytes': ProcessInfo.maxRss,
    'width': result.width,
    'height': result.height,
    'previewWidth': result.preview.width,
    'previewHeight': result.preview.height,
    'paletteBlocks': result.paletteBlocks,
    'fitsWorld': result.fitsWorld,
    'pixelMeanError': result.pixelMeanError,
    'blurredMeanError': result.blurredMeanError,
  };
}

Uint8List _sourcePng() {
  final random = math.Random(20261015);
  final image = img.Image(width: 2048, height: 2048, numChannels: 3);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final noise = random.nextInt(25) - 12;
      image.setPixelRgb(
        x,
        y,
        (255 * x ~/ (image.width - 1) + noise).clamp(0, 255),
        (255 * y ~/ (image.height - 1) + noise).clamp(0, 255),
        ((x < image.width ~/ 2 ? 70 : 210) + noise).clamp(0, 255),
      );
    }
  }
  return img.encodePng(image);
}
