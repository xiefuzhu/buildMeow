import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'panel_support.dart';

/// Switching blocks off one chip at a time.
///
/// The listing behaviour lives in `params_panel_test.dart` and the palette-wide
/// controls in `params_panel_buttons_test.dart`. The three files are separate
/// because each gets its own test process, and the panel is heavy enough that
/// one process cannot pump it many times without the engine dying. See
/// `panel_support.dart`.
void main() {
  testWidgets('tapping a block switches that block off and keeps the colour', (
    tester,
  ) async {
    await pumpPanel(tester);
    final first = paletteGroup(13).first;
    await expandColour(tester, 13);

    await tester.tap(find.byKey(ValueKey(first.key)));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        '${panelPalette.length - 1}/${panelPalette.length} 方块',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a colour only disappears once all of its blocks are off', (
    tester,
  ) async {
    await pumpPanel(tester);
    final white = paletteGroup(13);
    await expandColour(tester, 13);

    for (final entry in white) {
      await tester.tap(find.byKey(ValueKey(entry.key)));
      await tester.pumpAndSettle();
    }

    expect(
      find.textContaining(
        '${panelPalette.length - white.length}/${panelPalette.length} 方块',
      ),
      findsOneWidget,
    );
  });
}
