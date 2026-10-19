import 'dart:async';
import 'dart:ui' as ui;

import 'package:build_meow/src/app.dart';
import 'package:build_meow/src/data/preferences.dart';
import 'package:build_meow/src/state/accessibility.dart';
import 'package:build_meow/src/state/display.dart';
import 'package:build_meow/src/theme.dart';
import 'package:build_meow/src/widgets/blueprint_viewer.dart';
import 'package:build_meow/src/pages/home_page.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plan_support.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'schema_version': 1}));
  tearDown(Preferences.flush);

  test('appearance settings round-trip and reject malformed scale', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c
        .read(accessibilityProvider.notifier)
        .set(highContrast: true, textScale: 1.75);
    await Preferences.flush();
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    await restored.read(accessibilityProvider.notifier).restore();
    expect(restored.read(accessibilityProvider).textScale, 1.75);
    expect(restored.read(accessibilityProvider).highContrast, isTrue);
    await Preferences.saveAccessibility('{"scale":999}');
    await restored.read(accessibilityProvider.notifier).restore();
    expect(restored.read(accessibilityProvider).textScale, 2);
    await Preferences.saveAccessibility('broken');
    await restored.read(accessibilityProvider.notifier).restore();
    expect(restored.read(accessibilityProvider).textScale, 2);
  });

  test('high contrast schemes have readable foregrounds in both themes', () {
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return ((x > y ? x : y) + 0.05) / ((x > y ? y : x) + 0.05);
    }

    for (final brightness in Brightness.values) {
      final s = AppTheme.contrastScheme(brightness);
      expect(contrast(s.onSurface, s.surface), greaterThanOrEqualTo(7));
      expect(
        contrast(s.onSurfaceVariant, s.surfaceContainerHigh),
        greaterThanOrEqualTo(4.5),
      );
      expect(contrast(s.onPrimary, s.primary), greaterThanOrEqualTo(4.5));
      expect(contrast(s.error, s.surface), greaterThanOrEqualTo(4.5));
    }
    expect(const AppTextScaler(TextScaler.linear(1.5), 2).scale(16), 48);
  });

  testWidgets('preview controls do not overlap at 200% text', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 700);
    addTearDown(tester.view.reset);
    final image = await tester.runAsync(
      () => createTestImage(width: 128, height: 128, cache: false),
    );
    addTearDown(image!.dispose);
    final c = ProviderContainer(
      overrides: [
        ...planOverrides(buildTestResult()),
        previewDecoderProvider.overrideWithValue((_) async => image.clone()),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(400, 700),
              textScaler: TextScaler.linear(2),
            ),
            child: HomePage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = tester.getRect(find.text('构图原图'));
    final rotate = tester.getRect(find.byTooltip('逆时针 90°'));
    expect(rotate.top, greaterThanOrEqualTo(toggle.bottom));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'all pages and parameter drawer fit narrow 200% text; keyboard reads cells',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 700);
      addTearDown(tester.view.reset);
      final c = ProviderContainer(
        overrides: [
          ...planOverrides(buildTestResult(mapsX: 2)),
          previewDecoderProvider.overrideWithValue(
            (_) => Completer<ui.Image>().future,
          ),
        ],
      );
      addTearDown(c.dispose);
      c
          .read(accessibilityProvider.notifier)
          .set(textScale: 2, highContrast: true);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: c, child: const BuildMeowApp()),
      );
      await tester.pumpAndSettle();
      final semantics = tester.ensureSemantics();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('参数').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Exercise lower sections too; list children lay out lazily.
      final drawerList = find
          .descendant(of: find.byType(Drawer), matching: find.byType(ListView))
          .first;
      for (var i = 0; i < 8; i++) {
        await tester.drag(drawerList, const Offset(0, -400));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      // Close drawer by tapping its scrim.
      await tester.tapAt(const Offset(10, 350));
      await tester.pumpAndSettle();
      for (final label in ['图纸', '材料', '导出', '设置']) {
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(label),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: label);
        if (label == '图纸') {
          final viewer = find.byType(BlueprintViewer);
          await tester.tapAt(tester.getRect(viewer).center);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.sendKeyEvent(LogicalKeyboardKey.home);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pumpAndSettle();
          expect(find.text('x 1  z 0'), findsOneWidget);
        }
        if (label == '材料' || label == '导出' || label == '设置') {
          final scroll = find.byType(CustomScrollView).hitTestable().first;
          for (var i = 0; i < 5; i++) {
            await tester.drag(scroll, const Offset(0, -350));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: '$label scrolling');
          }
        }
      }
      semantics.dispose();
    },
  );
}
