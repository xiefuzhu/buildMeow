import 'package:build_meow/src/data/pipeline.dart';
import 'package:build_meow/src/data/preferences.dart';
import 'package:build_meow/src/pages/materials_page.dart';
import 'package:build_meow/src/state/project.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapart_core/mapart_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plan_support.dart';

/// The shopping list, and hiding a block from it.
///
/// What matters: the numbers are the build's own, hiding is a display state
/// that the preview and the blueprint both see, and the whole thing survives
/// being written to disk.
void main() {
  late PipelineResult result;
  late MapPlan plan;

  setUpAll(() async {
    result = buildTestResult();
    plan = result.plan;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    // Complete queued preference writes while this test's clock is active.
    // A future left in a previous test's zone cannot be driven by the next one.
    var saved = false;
    Object? error;
    Preferences.flush().then(
      (_) => saved = true,
      onError: (Object reason) {
        error = reason;
        saved = true;
      },
    );
    for (var i = 0; i < 20 && !saved; i++) {
      await tester.pump();
    }
    expect(
      saved,
      isTrue,
      reason: 'preference writes must finish before teardown',
    );
    expect(error, isNull);
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    ProviderContainer? container,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1400);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: planOverrides(result),
        child: const MaterialApp(home: MaterialsPage()),
      ),
    );
    await settle(tester);
  }

  testWidgets('lists every block the build uses, most-used first', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.text('方块总数'), findsOneWidget);
    expect(find.text('${plan.totalBlocks} 个'), findsOneWidget);
    // The first line is the most-used block, which is the plan's own order.
    expect(find.text(plan.blocks.first.nameZh), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the count as blocks, stacks and leftovers', (
    tester,
  ) async {
    await pumpPage(tester);

    final first = MaterialLine(
      block: plan.blocks.first,
      count: plan.counts.first,
    );
    expect(find.text('${first.count}'), findsWidgets);
    expect(find.text('${first.stacks} 组 + ${first.rest}'), findsWidgets);
  });

  testWidgets('tapping a block hides it, and unhides it again', (tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: planOverrides(result),
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return const MaterialApp(home: MaterialsPage());
          },
        ),
      ),
    );
    await settle(tester);

    final key = plan.blocks.first.key;
    expect(container.read(hiddenBlockKeysProvider), isEmpty);

    await tester.tap(find.text(plan.blocks.first.nameZh).first);
    await settle(tester);

    expect(container.read(hiddenBlockKeysProvider), {key});
    // The derived set is what the preview and the viewer read, so it has to
    // follow.
    expect(container.read(hiddenPlanIndicesProvider), {0});
    expect(find.text('已隐藏 1 种'), findsOneWidget);

    await tester.tap(find.text(plan.blocks.first.nameZh).first);
    await settle(tester);

    expect(container.read(hiddenBlockKeysProvider), isEmpty);
    expect(container.read(hiddenPlanIndicesProvider), isEmpty);
  });

  testWidgets('holding a block shows that one alone', (tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: planOverrides(result),
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return const MaterialApp(home: MaterialsPage());
          },
        ),
      ),
    );
    await settle(tester);

    await tester.longPress(find.text(plan.blocks.first.nameZh).first);
    await settle(tester);

    expect(container.read(soloBlockKeyProvider), plan.blocks.first.key);
    // Everything except that one block is hidden from the picture.
    expect(
      container.read(hiddenPlanIndicesProvider).length,
      plan.blocks.length - 1,
    );
    expect(find.textContaining('只看:'), findsOneWidget);
    // And it can be switched off again from the chip.
    await tester.tap(find.byIcon(Icons.close));
    await settle(tester);
    expect(container.read(soloBlockKeyProvider), isNull);
  });

  testWidgets('the whole-list buttons switch everything at once', (
    tester,
  ) async {
    await pumpPage(tester);

    await tester.tap(find.text('全部隐藏'));
    await settle(tester);
    expect(find.text('已隐藏 ${plan.blocks.length} 种'), findsOneWidget);

    await tester.tap(find.text('全部显示'));
    await settle(tester);
    expect(find.textContaining('已隐藏'), findsNothing);
  });

  testWidgets('what was hidden is remembered', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text(plan.blocks.first.nameZh).first);
    await settle(tester);

    // Preference IO runs outside the widget test's simulated clock.
    final saved = await tester.runAsync(Preferences.loadHiddenBlocks);
    expect(saved, {plan.blocks.first.key});
  });
}
