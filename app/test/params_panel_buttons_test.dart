import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'panel_support.dart';

/// The palette-wide controls and the section's collapse.
///
/// Split out from `params_panel_toggle_test.dart` because each test file gets
/// its own `flutter test` process and the panel is the heaviest thing the suite
/// pumps; two pumps per process is what this machine can take before the engine
/// dies. See `panel_support.dart`.
void main() {
  testWidgets('the whole-palette buttons switch every block at once', (
    tester,
  ) async {
    await pumpPanel(tester);

    // The per-colour controls are not buttons, so this reaches the one at the
    // top of the section.
    await tester.tap(find.widgetWithText(TextButton, '全关'));
    await tester.pumpAndSettle();

    expect(find.textContaining('0/${panelPalette.length} 方块'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '全开'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('${panelPalette.length}/${panelPalette.length} 方块'),
      findsOneWidget,
    );
  });

  testWidgets('the section collapses and opens again', (tester) async {
    await pumpPanel(tester);
    expect(
      find.textContaining('${panelPalette.length}/${panelPalette.length} 方块'),
      findsOneWidget,
    );

    await tester.tap(find.text('调色板'));
    await tester.pumpAndSettle();
    // Collapsed: the summary stays, the controls go.
    expect(
      find.textContaining('${panelPalette.length}/${panelPalette.length} 方块'),
      findsOneWidget,
    );
    expect(find.text('全开'), findsNothing);

    await tester.tap(find.text('调色板'));
    await tester.pumpAndSettle();
    expect(find.text('全开'), findsOneWidget);
  });
}
