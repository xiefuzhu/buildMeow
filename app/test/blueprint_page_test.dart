import 'package:build_meow/src/data/pipeline.dart';
import 'package:build_meow/src/pages/blueprint_page.dart';
import 'package:build_meow/src/widgets/blueprint_viewer.dart';
import 'package:build_meow/src/state/project.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapart_core/mapart_core.dart';
import 'package:material_ui/material_ui.dart';

import 'plan_support.dart';

class _MutablePipeline extends FixedPipeline {
  _MutablePipeline(super.result);
  void publish(PipelineResult result) => state = AsyncData(result);
}

/// The blueprint viewer: the picture as a grid you can read.
///
/// The thing worth testing is that a tap lands on the cell the user aimed at
/// and that the readout then names that cell's block and height. The cell size
/// is computed from the viewport, so the test does the same arithmetic and taps
/// the middle of a known cell rather than a hard-coded pixel.
void main() {
  late PipelineResult single;
  late PipelineResult wide;

  setUpAll(() {
    single = buildTestResult();
    wide = buildTestResult(mapsX: 2, mapsY: 1);
  });

  Future<void> pump(WidgetTester tester, PipelineResult result) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: planOverrides(result),
        child: const MaterialApp(home: BlueprintPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The cell size the viewer derives, recomputed here from the real box.
  ({double cell, Offset origin}) geometry(
    WidgetTester tester,
    MapPlan plan,
    ({int x0, int y0, int x1, int y1}) bounds,
  ) {
    final paint = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .firstWhere((p) => p.painter is BlueprintPainter);
    final painter = paint.painter! as BlueprintPainter;
    return (
      cell: painter.cell,
      origin: tester.getRect(find.byWidget(paint)).topLeft,
    );
  }

  testWidgets('tapping a cell names its block, position and height', (
    tester,
  ) async {
    await pump(tester, single);
    final plan = single.plan;
    final bounds = plan.tileBounds(0, 0);
    final geometry0 = geometry(tester, plan, bounds);

    const x = 5;
    const y = 9;
    await tester.tapAt(
      geometry0.origin +
          Offset((x + 0.5) * geometry0.cell, (y + 0.5) * geometry0.cell),
    );
    await tester.pumpAndSettle();

    final block = plan.blockAt(x, y);
    expect(find.text(block.nameZh), findsOneWidget);
    expect(find.text(block.blockId), findsOneWidget);
    expect(find.text('x $x  z $y'), findsOneWidget);
    expect(find.text('Y ${plan.heightAt(x, y)}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('before a tap the readout invites one', (tester) async {
    await pump(tester, single);

    expect(find.text('点一下格子,看这一格是什么方块、要多高'), findsOneWidget);
  });

  testWidgets('a single-map picture offers the two views', (tester) async {
    await pump(tester, single);

    expect(find.text('单张'), findsOneWidget);
    expect(find.text('整幅'), findsOneWidget);
    // Nothing to page through when there is one map.
    expect(find.textContaining('张 · 第'), findsNothing);
  });

  testWidgets('switching to the whole picture reports its size', (
    tester,
  ) async {
    await pump(tester, single);

    await tester.tap(find.text('整幅'));
    await tester.pumpAndSettle();

    expect(
      find.text('${single.plan.width} x ${single.plan.height} 格 · 每 16 格一条区块线'),
      findsOneWidget,
    );
  });

  testWidgets('a two-map picture pages between its maps', (tester) async {
    await pump(tester, wide);

    expect(find.textContaining('第 1/2 张 · 第 1 行 第 1 列'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    expect(find.textContaining('第 2/2 张 · 第 1 行 第 2 列'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.textContaining('第 1/2 张'), findsOneWidget);
  });

  testWidgets('paging to the second map moves the grid to its columns', (
    tester,
  ) async {
    await pump(tester, wide);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    // The tap must be read in the second tile's coordinates, not the first's:
    // this is the bug that would put the readout one map out.
    final plan = wide.plan;
    final bounds = plan.tileBounds(1, 0);
    final geometry0 = geometry(tester, plan, bounds);

    const localX = 4;
    const localY = 7;
    await tester.tapAt(
      geometry0.origin +
          Offset(
            (localX + 0.5) * geometry0.cell,
            (localY + 0.5) * geometry0.cell,
          ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('x ${bounds.x0 + localX}  z ${bounds.y0 + localY}'),
      findsOneWidget,
    );
  });

  testWidgets('an empty page says where to go first', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: BlueprintPage())),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有生成过,先去「生成」页选一张图片'), findsOneWidget);
  });

  testWidgets('a smaller regenerated plan clears an out-of-range picked cell', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 900);
    addTearDown(tester.view.reset);
    final pipeline = _MutablePipeline(wide);
    final overrides = planOverrides(wide)..removeLast();
    final c = ProviderContainer(
      overrides: [...overrides, resultProvider.overrideWith(() => pipeline)],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: BlueprintPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();
    final g = geometry(tester, wide.plan, wide.plan.tileBounds(1, 0));
    await tester.tapAt(g.origin + Offset(5.5 * g.cell, 9.5 * g.cell));
    await tester.pumpAndSettle();
    expect(find.text('x 133  z 9'), findsOneWidget);
    pipeline.publish(single);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('点一下格子,看这一格是什么方块、要多高'), findsOneWidget);
  });

  testWidgets('zoom keeps toolbar visible and reset restores all corners', (
    tester,
  ) async {
    await pump(tester, wide);
    final reset = find.byTooltip('复位视图');
    final toolbarRect = tester.getRect(reset);
    final viewerRect = tester.getRect(find.byType(BlueprintViewer));
    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: viewerRect.center,
        scrollDelta: const Offset(0, 600),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(reset), toolbarRect);
    expect(tester.hitTestOnBinding(toolbarRect.center).path, isNotEmpty);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    await tester.tap(find.text('整幅'));
    await tester.pumpAndSettle();
    final paint = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .firstWhere((p) => p.painter is BlueprintPainter);
    final painter = paint.painter! as BlueprintPainter;
    final canvas = tester.getRect(find.byWidget(paint));
    final viewport = tester.getRect(find.byType(BlueprintViewer));
    expect(painter.cell * wide.width, lessThanOrEqualTo(canvas.width));
    expect(painter.cell * wide.height, lessThanOrEqualTo(canvas.height));
    expect(viewport.contains(canvas.topLeft), isTrue);
    expect(
      viewport.contains(canvas.bottomRight - const Offset(0.01, 0.01)),
      isTrue,
    );
    await tester.tapAt(
      canvas.topLeft +
          Offset(
            (wide.width - 0.5) * painter.cell,
            (wide.height - 0.5) * painter.cell,
          ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('x ${wide.width - 1}  z ${wide.height - 1}'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('large overview fits completely in a short viewport', (
    tester,
  ) async {
    await pump(tester, wide);
    tester.view.physicalSize = const Size(760, 300);
    await tester.tap(find.text('整幅'));
    await tester.pumpAndSettle();
    final paint = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .firstWhere((p) => p.painter is BlueprintPainter);
    final painter = paint.painter! as BlueprintPainter;
    final canvas = tester.getSize(find.byWidget(paint));
    expect(painter.cell * wide.width, lessThanOrEqualTo(canvas.width + 0.01));
    expect(painter.cell * wide.height, lessThanOrEqualTo(canvas.height + 0.01));
    expect(tester.takeException(), isNull);
  });
}
