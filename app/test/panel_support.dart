import 'dart:convert';
import 'dart:io';

import 'package:build_meow/src/state/project.dart';
import 'package:build_meow/src/widgets/params_panel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapart_core/mapart_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Shared fixtures for the parameter panel's tests.
///
/// The panel is the most expensive widget in the app to pump: 61 colour groups
/// and 323 block chips, every one of them laid out because the palette section
/// is a `Column` inside the scrolling panel and a `Column` builds all of its
/// children.
///
/// That is why the panel's tests are spread over two files rather than one.
/// On this machine `flutter_tester.exe` (the engine build that ships with
/// Flutter 3.47.7 here) dies with a native access violation — `c0000005`, at a
/// fixed offset `0x35aaf0` in the executable — while running widget tests. It
/// is probabilistic rather than tied to any one test: the same file passes
/// twice and crashes on the third run, and the test it dies in moves between
/// runs. Pumping the panel is the heaviest rendering the suite does, so it hits
/// the crash most often, and keeping each process to four pumps rather than
/// eight lowers the odds. It does not remove them; see the
/// "未验证 / Not verified" section of the root README.
///
/// The split is not cosmetic: before it, this file died on its sixth test and
/// the runner reported every test in it as "did not complete".

/// Core's assets live in its own package, so they are read from disk rather
/// than through `rootBundle`. That keeps the test independent of Flutter's
/// asset plumbing while still exercising the real data.
File _coreAsset(String name) {
  final file = File('../packages/mapart_core/assets/colors/$name');
  if (!file.existsSync()) {
    throw StateError(
      'missing ${file.absolute.path} — run `flutter test` from the app '
      'directory',
    );
  }
  return file;
}

final ColorTable panelTable = ColorTable.fromJson(
  jsonDecode(_coreAsset('mapartcraft.colors.json').readAsStringSync())
      as Map<String, dynamic>,
);

final VersionTable panelVersions = VersionTable.fromJson(
  jsonDecode(_coreAsset('versions.json').readAsStringSync())
      as Map<String, dynamic>,
);

final panelRules = BlockCapabilities.fromJson(
  jsonDecode(_coreAsset('block_capabilities.json').readAsStringSync())
      as Map<String, dynamic>,
);
final panelPalette = resolveProductionPalette(
  table: panelTable,
  version: panelVersions.latest,
  kind: ArtKind.mapItem,
  capabilities: panelRules,
);

class _PanelSettings extends SettingsNotifier {
  @override
  ProjectSettings build() => const ProjectSettings(artKind: ArtKind.mapItem);
}

/// A viewport tall enough to build the whole panel in one go, so the tiles do
/// not have to be scrolled to before they can be tapped.
Future<void> pumpPanel(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({'schema_version': 1});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(460, 3400);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(_PanelSettings.new),
        blockNamesProvider.overrideWith((ref) async => BlockNames.empty),
        blockCapabilitiesProvider.overrideWith((ref) async => panelRules),
        colorTableProvider.overrideWith((ref) async => panelTable),
        versionTableProvider.overrideWith((ref) async => panelVersions),
        blockColorsProvider.overrideWith((ref) async => const {}),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 460,
            height: 3400,
            child: ParamsPanel(onGenerate: () async {}),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every block of one base colour, as the panel builds it.
List<PaletteEntry> paletteGroup(int colorIndex) =>
    panelPalette.entriesForColor(colorIndex);

/// Opens a colour group so its blocks are in the tree.
Future<void> expandColour(WidgetTester tester, int colorIndex) async {
  final target = find.byKey(ValueKey('color-$colorIndex'));
  await tester.scrollUntilVisible(
    target,
    120,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.tap(target);
  await tester.pumpAndSettle();
}
