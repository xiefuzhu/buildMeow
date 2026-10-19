import 'package:build_meow/src/data/preferences.dart';
import 'package:build_meow/src/data/export.dart';
import 'package:build_meow/src/state/project.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapart_core/mapart_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What survives closing the app.
///
/// There is no project file system yet, so this is where "remembered" lives:
/// the settings, the blocks hidden from the picture, the solo selection and the
/// folder exports go to. Each one is a separate key and each has to come back
/// the way it went in, including the empty cases — a forgotten export folder is
/// the difference between a save dialog and a silent write.
void main() {
  setUp(() async {
    await Preferences.flush();
    SharedPreferences.setMockInitialValues({});
  });

  test('hidden blocks survive a save and a load', () async {
    await Preferences.saveHiddenBlocks({'white_concrete', 'black_wool'});

    expect(await Preferences.loadHiddenBlocks(), {
      'white_concrete',
      'black_wool',
    });
  });

  test('nothing hidden loads as an empty set, not an error', () async {
    expect(await Preferences.loadHiddenBlocks(), isEmpty);
  });

  test('the solo block is remembered and can be cleared', () async {
    await Preferences.saveSoloBlock('white_concrete');
    expect(await Preferences.loadSoloBlock(), 'white_concrete');

    await Preferences.saveSoloBlock(null);
    expect(await Preferences.loadSoloBlock(), isNull);
  });

  test('the export directory is remembered and can be forgotten', () async {
    await Preferences.saveExportDirectory(r'C:\out');
    expect(await Preferences.loadExportDirectory(), r'C:\out');

    await Preferences.saveExportDirectory(null);
    expect(await Preferences.loadExportDirectory(), isNull);
  });

  test('the settings round-trip through their own codec', () async {
    const settings = ProjectSettings(
      mapsX: 3,
      mapsY: 2,
      versionId: '1.20',
      maxBlocks: null,
      ditherThreshold: 4.5,
      disabledBlockKeys: {'a', 'b'},
      includeSupportBlocks: false,
      background: Rgb(1, 2, 3),
    );
    await Preferences.saveSettings(settings);

    final back = await Preferences.loadSettings();
    expect(back, isNotNull);
    expect(back!.mapsX, 3);
    expect(back.mapsY, 2);
    expect(back.versionId, VersionTable.defaultVersionId);
    expect(back.maxBlocks, isNull);
    expect(back.ditherThreshold, 4.5);
    expect(back.disabledBlockKeys, {'a', 'b'});
    expect(back.includeSupportBlocks, isFalse);
    expect(back.background, const Rgb(1, 2, 3));
  });

  test('no stored settings load as null rather than defaults', () async {
    // Null rather than a default object: the shell only restores when there is
    // something to restore, so a first run must not overwrite the state the
    // notifier was built with.
    expect(await Preferences.loadSettings(), isNull);
  });

  test(
    'a stored shape this build cannot read is discarded, not fatal',
    () async {
      SharedPreferences.setMockInitialValues({'settings': 'not json'});

      expect(await Preferences.loadSettings(), isNull);
    },
  );

  test('older schema preserves compatible settings and locations', () async {
    SharedPreferences.setMockInitialValues({
      'schema_version': 0,
      'hidden_blocks': <String>['white_concrete'],
      'export_dir': r'C:\old',
    });

    expect(await Preferences.loadHiddenBlocks(), {'white_concrete'});
    expect(await Preferences.loadExportDirectory(), r'C:\old');
  });

  test('theme and flat map settings survive the preference codec', () async {
    await Preferences.saveThemeMode('dark');
    await Preferences.saveSettings(
      const ProjectSettings(artKind: ArtKind.mapItem, flatMap: true),
    );
    expect(await Preferences.loadThemeMode(), 'dark');
    expect((await Preferences.loadSettings())!.flatMap, isTrue);
  });

  test(
    'export format, name and per-mode reference choices are remembered',
    () async {
      await Preferences.saveExportOptions(
        const ExportOptions(
          formats: {ExportFormat.pdf, ExportFormat.csv},
          baseName: 'my_cat',
          shape: ExportShape.solid,
          pngCell: 12,
          referenceRows: {ArtKind.mapItem: false, ArtKind.blockPixels: true},
        ),
      );
      final saved = (await Preferences.loadExportOptions())!;
      expect(saved.formats, {ExportFormat.pdf, ExportFormat.csv});
      expect(saved.baseName, 'my_cat');
      expect(saved.shape, ExportShape.solid);
      expect(saved.pngCell, 12);
      expect(saved.referenceRows, {
        ArtKind.mapItem: false,
        ArtKind.blockPixels: true,
      });
    },
  );
}
