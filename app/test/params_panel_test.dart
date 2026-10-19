import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'panel_support.dart';

/// What the palette section shows: every block of every colour, counted per
/// colour, and which colours are open.
///
/// The switching behaviour — tapping a chip, the whole-palette buttons — lives
/// in `params_panel_toggle_test.dart`, because this file and that one each get
/// their own test process and the panel is expensive enough that one process
/// cannot pump it eight times. See `panel_support.dart`.
void main() {
  testWidgets('the palette offers every block, not one per colour', (
    tester,
  ) async {
    await pumpPanel(tester);

    expect(find.text('调色板'), findsOneWidget);
    // Collapsed by default, so the header carries the summary.
    expect(
      find.textContaining('${panelPalette.length}/${panelPalette.length} 方块'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('colours are collapsed until asked for', (tester) async {
    await pumpPanel(tester);
    // The whole point of the collapse: sixty colours' worth of chips is not in
    // the tree until it is wanted.
    expect(find.byKey(ValueKey(paletteGroup(13).first.key)), findsNothing);

    await expandColour(tester, 13);
    expect(find.byKey(ValueKey(paletteGroup(13).first.key)), findsOneWidget);
  });

  testWidgets('each colour shows one chip per candidate block', (tester) async {
    await pumpPanel(tester);
    await expandColour(tester, 13);

    // White Wool has several blocks, all rendering identically: that is the
    // whole reason the palette is grouped by colour.
    final white = paletteGroup(13);
    expect(white.length, greaterThan(1));
    expect(white.map((e) => e.name).toSet(), {'White Wool'});

    for (final entry in white) {
      expect(
        find.byKey(ValueKey(entry.key)),
        findsOneWidget,
        reason: entry.blockName,
      );
    }
    // And each one says what it is, which a bare swatch could not.
    expect(find.text(white.first.blockName), findsWidgets);
  });

  testWidgets('unsupported Water is explained instead of offered', (
    tester,
  ) async {
    await pumpPanel(tester);
    expect(paletteGroup(10), isEmpty);
    await tester.tap(find.text('查看不可用方块及原因'));
    await tester.pumpAndSettle();
    expect(find.text('不可用方块'), findsOneWidget);
    expect(panelRules.mapReasons['water'], contains('液体'));
  });
}
