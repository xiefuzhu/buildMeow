import 'dart:async';

import 'package:build_meow/src/widgets/title_bar.dart';
import 'package:build_meow/src/widgets/app_logo.dart';
import 'package:build_meow/src/window/window_controls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

/// The bar the way `AppShell` uses it: a normal [Scaffold] app bar.
Widget _shell() => MaterialApp(
  home: Scaffold(appBar: const AppTitleBar(), body: const SizedBox.expand()),
);

void main() {
  const dragChannel = MethodChannel('build_meow/window_drag');

  tearDown(() {
    WindowControls.enabled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(dragChannel, null);
  });
  testWidgets('the title bar builds as an ordinary app bar', (tester) async {
    await tester.pumpWidget(_shell());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('建喵!'), findsOneWidget);
    expect(find.byType(AppTitleBar), findsOneWidget);
    expect(tester.getSize(find.byType(AppBar)).height, kTitleBarHeight);
  });

  testWidgets('the three window buttons are there', (tester) async {
    await tester.pumpWidget(_shell());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.horizontal_rule), findsOneWidget);
    expect(find.byIcon(Icons.crop_square), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('the label sits in the app bar title, centred in the toolbar', (
    tester,
  ) async {
    // Regression guard for the alignment bug: the label used to live in
    // `flexibleSpace`, which fills the whole bar, so the text ended up against
    // the top edge instead of centred.
    await tester.pumpWidget(_shell());
    await tester.pumpAndSettle();

    final bar = tester.getRect(find.byType(AppBar));
    final label = tester.getRect(find.text('建喵!'));
    final centreGap = (label.center.dy - bar.center.dy).abs();
    expect(centreGap, lessThan(1.5), reason: 'label centre $label bar $bar');

    // The selected icon, matching the executable and About card.
    expect(find.byType(AppLogo), findsOneWidget);
    expect(find.byIcon(Icons.grid_view_rounded), findsNothing);
  });

  testWidgets('the drag area does not use DragToMoveArea', (tester) async {
    // The drag must hang off one `GestureDetector`'s `onPanStart`, so a plain
    // click never enters the synchronous modal move loop that
    // `startDragging` runs on Windows. Two competing detectors, which is what
    // `DragToMoveArea` plus a nested double-tap detector amounts to, can let
    // the arena decide the drag after the button is already up — and then the
    // loop waits for a release that never comes.
    await tester.pumpWidget(_shell());
    await tester.pumpAndSettle();
    expect(find.byType(DragToMoveArea), findsNothing);
  });

  testWidgets('clicking and dragging the bar is safe', (tester) async {
    // With no window every window call is a no-op, so this asserts the gesture
    // wiring rather than its effect.
    await tester.pumpWidget(_shell());
    await tester.pumpAndSettle();

    await tester.tap(find.text('建喵!'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // The bar drags from empty space too, not only from the label.
    final bar = tester.getRect(find.byType(AppBar));
    await tester.dragFrom(
      Offset(bar.center.dx, bar.center.dy),
      const Offset(40, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.drag(find.text('建喵!'), const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('with no window the bar is not shown', (tester) async {
    // `WindowControls.enabled` is only set by `main`, so this is the state of
    // every widget test and every non-desktop build.
    expect(WindowControls.enabled, isFalse);
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    expect(find.byType(AppTitleBar), findsNothing);
  });

  testWidgets('drag coalesces moves and never sends client coordinates', (
    tester,
  ) async {
    WindowControls.enabled = true;
    final calls = <MethodCall>[];
    final move = Completer<void>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      dragChannel,
      (call) async {
        calls.add(call);
        if (call.method == 'begin') return true;
        if (call.method == 'update' && calls.length == 2) await move.future;
        return null;
      },
    );
    await tester.pumpWidget(_shell());
    final detector = tester.widget<GestureDetector>(
      find.byWidgetPredicate(
        (w) => w is GestureDetector && w.onPanStart != null,
      ),
    );
    detector.onPanStart!(
      DragStartDetails(globalPosition: const Offset(100, 20)),
    );
    await tester.pump();
    for (final x in [140.0, 110.0, 100.0, 160.0]) {
      detector.onPanUpdate!(DragUpdateDetails(globalPosition: Offset(x, 20)));
    }
    await tester.pump();
    expect(calls.map((c) => c.method), ['begin', 'update']);
    move.complete();
    await tester.pump();
    expect(calls.map((c) => c.method), ['begin', 'update', 'update']);
    expect(calls.every((c) => c.arguments == null), isTrue);
    detector.onPanEnd!(DragEndDetails());
    await tester.pump();
    expect(calls.last.method, 'end');
    expect(tester.takeException(), isNull);
  });

  testWidgets('release before drag initialization cannot restart movement', (
    tester,
  ) async {
    WindowControls.enabled = true;
    final ready = Completer<bool>();
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      dragChannel,
      (call) async {
        calls.add(call.method);
        if (call.method == 'begin') return ready.future;
        return null;
      },
    );
    await tester.pumpWidget(_shell());
    final detector = tester.widget<GestureDetector>(
      find.byWidgetPredicate(
        (w) => w is GestureDetector && w.onPanStart != null,
      ),
    );
    detector.onPanStart!(
      DragStartDetails(globalPosition: const Offset(100, 20)),
    );
    await tester.pump();
    detector.onPanUpdate!(
      DragUpdateDetails(globalPosition: const Offset(160, 20)),
    );
    detector.onPanCancel!();
    await tester.pump();
    ready.complete(true);
    await tester.pump();
    expect(calls, ['begin', 'end']);
    expect(tester.takeException(), isNull);
  });
}
