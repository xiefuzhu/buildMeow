import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapart_core/mapart_core.dart';

import '../data/pipeline.dart';
import 'project.dart';

final pipelineWorkerProvider = Provider<PipelineWorker>((ref) {
  final worker = PipelineWorker();
  ref.onDispose(worker.cancel);
  return worker;
});

/// Injectable execution boundary for deterministic scheduling and failure tests.
final pipelineRunnerProvider =
    Provider<Future<PipelineResult> Function(PipelineRequest)>(
      (ref) => ref.watch(pipelineWorkerProvider).run,
    );

final resultProvider = AsyncNotifierProvider<PipelineNotifier, PipelineResult?>(
  PipelineNotifier.new,
);

/// Scheduling belongs to the project, so switching pages cannot stop generation.
class PipelineNotifier extends AsyncNotifier<PipelineResult?> {
  Timer? _timer;
  int _revision = 0;
  bool _busy = false;
  bool _pending = false;
  bool _disposed = false;
  Future<void>? _active;

  @override
  PipelineResult? build() {
    final worker = ref.read(pipelineWorkerProvider);
    ref.listen(sourceImageProvider, (before, after) {
      if (!identical(before, after)) clear();
    });
    ref.listen(settingsProvider, (before, after) {
      if (before == null || after.affectsRender(before)) clear();
    });
    ref.onDispose(() {
      _disposed = true;
      _revision++;
      _timer?.cancel();
      worker.cancel();
    });
    if (ref.read(sourceImageProvider) != null) _schedule();
    return null;
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 220), () {
      if (!_disposed && ref.read(sourceImageProvider) != null) {
        unawaited(generate());
      }
    });
  }

  void clear() {
    _revision++;
    _timer?.cancel();
    _pending = _busy && ref.read(sourceImageProvider) != null;
    ref.read(pipelineWorkerProvider).cancel();
    state = _busy && _pending
        ? const AsyncLoading<PipelineResult?>()
        : const AsyncData<PipelineResult?>(null);
    if (ref.read(sourceImageProvider) != null) _schedule();
  }

  Future<void> generate() {
    _timer?.cancel();
    if (_busy) {
      return _active ?? Future<void>.value();
    }
    final source = ref.read(sourceImageProvider);
    if (source == null) {
      state = AsyncError(StateError('请先选择一张图片'), StackTrace.current);
      return Future<void>.value();
    }
    final settings = ref.read(settingsProvider);
    final revision = _revision;
    _busy = true;
    _pending = false;
    state = const AsyncLoading<PipelineResult?>();
    return _active = _run(source, settings, revision);
  }

  Future<void> _run(
    SourceImage source,
    ProjectSettings settings,
    int revision,
  ) async {
    try {
      // Start independent asset reads together, and route every failure through
      // the same recoverable result state.
      final tables = ref.read(colorTableProvider.future);
      final versions = ref.read(versionTableProvider.future);
      final colors = ref.read(blockColorsProvider.future);
      final names = ref.read(blockNamesProvider.future);
      final textures = ref.read(textureAtlasProvider.future);
      final capabilities = ref.read(blockCapabilitiesProvider.future);
      final runner = ref.read(pipelineRunnerProvider);
      final loaded = await Future.wait<Object>([
        tables,
        versions,
        colors,
        names,
        textures,
        capabilities,
      ]);
      final table = loaded[0] as ColorTable;
      final versionTable = loaded[1] as VersionTable;
      final blockColors = loaded[2] as Map<String, int>;
      final blockNames = loaded[3] as BlockNames;
      final atlas =
          loaded[4] as ({Uint8List png, Map<String, int> index, int cell});
      final rules = loaded[5] as BlockCapabilities;
      if (_disposed || revision != _revision) return;
      final version = versionTable.require(settings.versionId);
      final height = suggestHeightPlan(version);
      final blocks = settings.artKind == ArtKind.blockPixels;
      final palette = resolveProductionPalette(
        table: table,
        version: version,
        kind: settings.artKind,
        flatMap: settings.flatMap,
        blockColors: blockColors,
        capabilities: rules,
      );
      final result = await runner(
        PipelineRequest(
          encodedImage: source.bytes,
          artKind: settings.artKind,
          flatMap: settings.flatMap,
          productionPalette: palette,
          colorTable: table,
          versionTable: versionTable,
          versionId: settings.versionId,
          mapsX: settings.mapsX,
          mapsY: settings.mapsY,
          cropMode: settings.cropMode,
          dither: settings.dither,
          ditherThreshold: settings.ditherThreshold,
          ditherStrength: settings.ditherStrength,
          maxBlocks: settings.maxBlocks,
          metric: settings.metric,
          driftBudget: settings.dither == DitherMode.none
              ? null
              : height.driftBudget,
          background: settings.background,
          disabledBlockKeys: settings.disabledBlockKeys,
          includeSupportBlocks: false,
          blockNames: blockNames,
          blockColors: blocks ? blockColors : const {},
          textureAtlas: blocks ? atlas.png : null,
          textureIndex: blocks ? atlas.index : const {},
          textureCell: atlas.cell,
          flatnessWeight: 5,
          baseHeight: height.baseHeight,
        ),
      );
      if (!_disposed && revision == _revision) state = AsyncData(result);
    } on Object catch (error, stack) {
      if (!_disposed && revision == _revision) state = AsyncError(error, stack);
    } finally {
      _busy = false;
      _active = null;
      if (!_disposed && _pending && ref.read(sourceImageProvider) != null) {
        _pending = false;
        _schedule();
      }
    }
  }
}
