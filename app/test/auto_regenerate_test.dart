import 'dart:async';
import 'dart:typed_data';

import 'package:build_meow/src/data/pipeline.dart';
import 'package:build_meow/src/state/project.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapart_core/mapart_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plan_support.dart';

SourceImage source(int id) => SourceImage(
  name: '$id.png',
  bytes: Uint8List.fromList([id]),
  width: 1,
  height: 1,
);

class _CancellableWorker extends PipelineWorker {
  void Function()? onCancel;

  @override
  void cancel() => onCancel?.call();
}

void main() {
  final base = buildTestRequest();
  final firstResult = buildTestResult();
  setUp(() => SharedPreferences.setMockInitialValues({'schema_version': 1}));

  ProviderContainer container(
    Future<PipelineResult> Function(PipelineRequest) runner, {
    bool failAssets = false,
    PipelineWorker? worker,
  }) {
    final result = ProviderContainer(
      overrides: [
        colorTableProvider.overrideWith((ref) async {
          if (failAssets) throw StateError('asset unavailable');
          return base.colorTable;
        }),
        versionTableProvider.overrideWith((ref) async => base.versionTable),
        blockColorsProvider.overrideWith((ref) async => const {}),
        blockNamesProvider.overrideWith((ref) async => BlockNames.empty),
        blockCapabilitiesProvider.overrideWith(
          (ref) async => const BlockCapabilities({}, {}),
        ),
        textureAtlasProvider.overrideWith(
          (ref) async => (png: Uint8List(0), index: <String, int>{}, cell: 16),
        ),
        pipelineRunnerProvider.overrideWithValue(runner),
        if (worker != null) pipelineWorkerProvider.overrideWithValue(worker),
      ],
    );
    result.read(settingsProvider.notifier).setArtKind(ArtKind.mapItem);
    result.read(resultProvider);
    addTearDown(result.dispose);
    return result;
  }

  test(
    'a burst of edits produces one solve using the latest settings',
    () async {
      final requests = <PipelineRequest>[];
      final c = container((request) async {
        requests.add(request);
        return firstResult;
      });
      c.read(sourceImageProvider.notifier).set(source(1));
      c.read(settingsProvider.notifier).setMaps(x: 2);
      c.read(settingsProvider.notifier).setMaps(x: 3);
      await Future<void>.delayed(const Duration(milliseconds: 280));
      expect(requests, hasLength(1));
      expect(requests.single.mapsX, 3);
      expect(c.read(resultProvider).value, same(firstResult));
    },
  );

  test(
    'changing source during a solve never publishes its stale result',
    () async {
      final gates = <Completer<PipelineResult>>[];
      final requests = <PipelineRequest>[];
      final c = container((request) {
        requests.add(request);
        final gate = Completer<PipelineResult>();
        gates.add(gate);
        return gate.future;
      });
      c.read(sourceImageProvider.notifier).set(source(1));
      final active = c.read(resultProvider.notifier).generate();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(requests, hasLength(1));
      c.read(sourceImageProvider.notifier).set(source(2));
      c.read(settingsProvider.notifier).setMaps(x: 2);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(requests, hasLength(1), reason: 'no overlapping expensive solves');
      gates.first.complete(firstResult);
      await active;
      expect(c.read(resultProvider).value, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(requests, hasLength(2));
      expect(requests.last.encodedImage.single, 2);
      expect(requests.last.mapsX, 2);
      gates.last.complete(firstResult);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.read(resultProvider).value, same(firstResult));
    },
  );

  test(
    'obsolete work is cancelled and latest settings restart automatically',
    () async {
      final worker = _CancellableWorker();
      final first = Completer<PipelineResult>();
      final requests = <PipelineRequest>[];
      final c = container((request) {
        requests.add(request);
        return requests.length == 1 ? first.future : Future.value(firstResult);
      }, worker: worker);
      worker.onCancel = () {
        if (requests.isNotEmpty && !first.isCompleted) {
          first.completeError(const PipelineCancelled());
        }
      };
      c.read(sourceImageProvider.notifier).set(source(1));
      final active = c.read(resultProvider.notifier).generate();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(requests, hasLength(1));
      c.read(settingsProvider.notifier).setMaps(x: 2);
      await active.timeout(const Duration(seconds: 2));
      expect(c.read(resultProvider).hasError, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 280));
      expect(requests, hasLength(2));
      expect(requests.last.mapsX, 2);
      expect(c.read(resultProvider).value, same(firstResult));
    },
  );

  test(
    'clearing a source discards a late failure without restarting',
    () async {
      final gate = Completer<PipelineResult>();
      var calls = 0;
      final c = container((_) {
        calls++;
        return gate.future;
      });
      c.read(sourceImageProvider.notifier).set(source(1));
      final active = c.read(resultProvider.notifier).generate();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      c.read(sourceImageProvider.notifier).clear();
      gate.completeError(StateError('obsolete failure'));
      await active;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(c.read(resultProvider).hasError, isFalse);
      expect(c.read(resultProvider).value, isNull);
      expect(calls, 1);
    },
  );

  test('asset failures become a recoverable error state', () async {
    final c = container((_) async => firstResult, failAssets: true);
    c.read(sourceImageProvider.notifier).set(source(1));
    await c.read(resultProvider.notifier).generate();
    expect(c.read(resultProvider).hasError, isTrue);
    expect(c.read(resultProvider).isLoading, isFalse);
  });

  test(
    'disposing cancels active work rather than waiting for a result',
    () async {
      final worker = _CancellableWorker();
      final gate = Completer<PipelineResult>();
      var started = false;
      final c = container((_) {
        started = true;
        return gate.future;
      }, worker: worker);
      worker.onCancel = () {
        if (started && !gate.isCompleted) {
          gate.completeError(const PipelineCancelled());
        }
      };
      c.read(sourceImageProvider.notifier).set(source(1));
      final active = c.read(resultProvider.notifier).generate();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      c.dispose();
      await active.timeout(const Duration(seconds: 2));
      expect(gate.isCompleted, isTrue);
    },
  );

  test('disposing a project safely ignores a running completion', () async {
    final gate = Completer<PipelineResult>();
    final c = container((_) => gate.future);
    c.read(sourceImageProvider.notifier).set(source(1));
    final active = c.read(resultProvider.notifier).generate();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    c.dispose();
    gate.complete(firstResult);
    await active;
  });
}
