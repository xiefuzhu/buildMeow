import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:build_meow/src/app.dart';
import 'package:build_meow/src/pages/home_page.dart';
import 'package:build_meow/src/state/display.dart';
import 'package:build_meow/src/state/project.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapart_core/mapart_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plan_support.dart';

void main() {
  final result = buildTestResult();
  setUp(() => SharedPreferences.setMockInitialValues({'schema_version': 1}));

  testWidgets('five-page shell resizes and exposes semantics', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);
    final c = ProviderContainer(
      overrides: [
        ...planOverrides(result),
        previewDecoderProvider.overrideWithValue(
          (_) => Completer<ui.Image>().future,
        ),
      ],
    );
    addTearDown(c.dispose);
    c.read(settingsProvider.notifier).setArtKind(ArtKind.mapItem);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const BuildMeowApp()),
    );
    await tester.pumpAndSettle();
    final semantics = tester.ensureSemantics();
    expect(find.text('作品模式'), findsOneWidget);
    expect(
      find
          .byType(ExcludeSemantics)
          .evaluate()
          .where((e) => (e.widget as ExcludeSemantics).child is AppShell),
      isEmpty,
    );
    for (final size in [const Size(800, 700), const Size(400, 800)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('参数'), findsWidgets);
    }
    semantics.dispose();
  });

  testWidgets('a late hidden redraw is discarded before native decoding', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
    final gate = Completer<RgbaImage>();
    final decoded = <RgbaImage>[];
    final c = ProviderContainer(
      overrides: [
        ...planOverrides(result),
        textureAtlasProvider.overrideWith(
          (ref) async => (png: Uint8List(0), index: <String, int>{}, cell: 16),
        ),
        previewRasterizerProvider.overrideWithValue((_) => gate.future),
        previewDecoderProvider.overrideWithValue((image) {
          decoded.add(image);
          return Completer<ui.Image>().future;
        }),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();
    c
        .read(hiddenBlockKeysProvider.notifier)
        .set(result.plan.blocks.first.key, true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    c.read(hiddenBlockKeysProvider.notifier).showAll();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final obsolete = RgbaImage(result.width, result.height);
    gate.complete(obsolete);
    await tester.pumpAndSettle();
    expect(decoded, isNotEmpty);
    expect(
      decoded.any((image) => identical(image, obsolete)),
      isFalse,
      reason: 'a superseded redraw must not decode or publish its image',
    );
    expect(tester.takeException(), isNull);
  });
}
