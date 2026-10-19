import 'package:build_meow/src/data/export.dart';
import 'package:build_meow/src/data/pipeline.dart';
import 'package:build_meow/src/pages/export_page.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'plan_support.dart';

/// The export page: what to write, in what shape, and where it went.
///
/// The two choices that decide what someone has to build — surface or solid,
/// and whether the reference row is in the file — are the ones this checks are
/// reachable and say what they mean. The files themselves are checked in
/// `export_data_test.dart`, which never touches a widget.
void main() {
  late PipelineResult result;

  setUpAll(() {
    result = buildTestResult();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1600);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: planOverrides(result),
        child: const MaterialApp(home: ExportPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('it offers every format, both shapes and the reference row', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('文件'), findsOneWidget);
    expect(find.text('投影内容'), findsOneWidget);
    expect(find.text('文件名与位置'), findsOneWidget);

    for (final format in ExportFormat.values) {
      expect(find.text(format.label), findsOneWidget, reason: format.name);
    }
    expect(find.text('只要表层'), findsOneWidget);
    expect(find.text('实心'), findsOneWidget);
    expect(find.text('包含最北边的参照行'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '导出'), findsOneWidget);
  });

  testWidgets('every format starts selected, and one can be switched off', (
    tester,
  ) async {
    await pump(tester);

    CheckboxListTile box(ExportFormat format) =>
        tester.widget<CheckboxListTile>(
          find.widgetWithText(CheckboxListTile, format.label),
        );

    expect(box(ExportFormat.csv).value, isTrue);

    await tester.tap(find.text(ExportFormat.csv.label));
    await tester.pumpAndSettle();

    expect(box(ExportFormat.csv).value, isFalse);
    // And the others are untouched.
    expect(box(ExportFormat.pdf).value, isTrue);
  });

  testWidgets('surface is the default and explains itself', (tester) async {
    await pump(tester);

    expect(find.textContaining('每列只放最上面那一块'), findsOneWidget);
    expect(find.textContaining('填到表层'), findsNothing);
  });

  testWidgets('choosing solid warns how big the file gets', (tester) async {
    await pump(tester);

    await tester.tap(find.text('实心'));
    await tester.pumpAndSettle();

    expect(find.textContaining('填到表层'), findsOneWidget);
    expect(find.textContaining('方块数会大很多'), findsOneWidget);
  });

  testWidgets('the reference row can be left out', (tester) async {
    await pump(tester);

    SwitchListTile toggle() => tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '包含最北边的参照行'),
    );
    expect(toggle().value, isTrue);

    await tester.tap(find.text('包含最北边的参照行'));
    await tester.pumpAndSettle();

    expect(toggle().value, isFalse);
  });

  testWidgets('the file name prefix is editable and feeds the export', (
    tester,
  ) async {
    await pump(tester);

    final field = find.byType(TextField);
    expect(tester.widget<TextField>(field).controller!.text, 'mapart');

    await tester.enterText(field, 'my cat');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, 'my cat');
  });

  testWidgets('it says where the files will go, and that it is not guessed', (
    tester,
  ) async {
    await pump(tester);

    // On a desktop test host there is no folder picked yet, so the page says so
    // rather than silently writing into the game's own directory.
    expect(find.textContaining('还没有选文件夹'), findsOneWidget);
    expect(find.textContaining('.minecraft/schematics'), findsOneWidget);
  });

  testWidgets('an empty page says where to go first', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1600);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: ExportPage())),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有生成过,先去「生成」页选一张图片'), findsOneWidget);
  });
}
