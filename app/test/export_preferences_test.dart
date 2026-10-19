import 'dart:convert';

import 'package:build_meow/src/data/export.dart';
import 'package:build_meow/src/data/preferences.dart';
import 'package:build_meow/src/pages/export_page.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapart_core/mapart_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plan_support.dart';

void main() {
  testWidgets('export controls restore saved choices after page recreation', (
    tester,
  ) async {
    final result = buildTestResult();
    SharedPreferences.setMockInitialValues({
      'schema_version': 1,
      'export_options': jsonEncode(
        const ExportOptions(
          formats: {ExportFormat.pdf},
          shape: ExportShape.solid,
          baseName: 'saved_cat',
          referenceRows: {ArtKind.mapItem: false},
        ).toJson(),
      ),
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1800);
    addTearDown(tester.view.reset);

    Future<void> open() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: planOverrides(result),
          child: const MaterialApp(home: ExportPage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    await open();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'saved_cat',
    );
    expect(
      tester
          .widget<SegmentedButton<ExportShape>>(
            find.byType(SegmentedButton<ExportShape>),
          )
          .selected,
      {ExportShape.solid},
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, '包含最北边的参照行'),
          )
          .value,
      isFalse,
    );
    for (final format in ExportFormat.values) {
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, format.label),
            )
            .value,
        format == ExportFormat.pdf,
      );
    }

    await tester.enterText(find.byType(TextField), 'updated_cat');
    await tester.pumpAndSettle();
    var saved = false;
    Preferences.flush().then((_) => saved = true);
    for (var i = 0; i < 20 && !saved; i++) {
      await tester.pump();
    }
    expect(saved, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await open();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'updated_cat',
    );
    expect(tester.takeException(), isNull);
  });
}
