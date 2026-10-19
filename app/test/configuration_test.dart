import 'dart:async';
import 'dart:typed_data';

import 'package:build_meow/src/data/preferences.dart';
import 'package:build_meow/src/state/project.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapart_core/mapart_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'schema_version': 1}));
  test(
    'new settings retain the image and valid stored cropping is preserved',
    () {
      expect(const ProjectSettings().cropMode, CropMode.contain);
      expect(
        ProjectSettings.fromJson({'cropMode': 'cover'}).cropMode,
        CropMode.cover,
      );
    },
  );
  test('malformed settings recover to supported, bounded values', () {
    final settings = ProjectSettings.fromJson({
      'mapsX': -1,
      'mapsY': 9000,
      'versionId': 'obsolete',
      'ditherStrength': 4,
      'ditherThreshold': -50,
      'disabledBlockKeys': [1, 'stone', null],
      'background': [-1, 999, 'bad'],
      'maxBlocks': 'bad',
    });
    expect(settings.mapsX, 1);
    expect(settings.mapsY, 16);
    expect(settings.versionId, VersionTable.defaultVersionId);
    expect(settings.ditherStrength, 1);
    expect(settings.ditherThreshold, 0);
    expect(settings.disabledBlockKeys, {'stone'});
    expect(settings.background, const Rgb(0, 255, 255));
    expect(settings.maxBlocks, 60);
  });
  test('late restore cannot overwrite a newer edit', () async {
    final gate = Completer<ProjectSettings?>();
    final container = ProviderContainer(
      overrides: [settingsLoaderProvider.overrideWithValue(() => gate.future)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    final restore = notifier.restore();
    notifier.setMaps(x: 4);
    gate.complete(const ProjectSettings(mapsX: 12));
    await restore;
    expect(container.read(settingsProvider).mapsX, 4);
  });
  test('schema migration only removes owned settings', () async {
    SharedPreferences.setMockInitialValues({
      'schema_version': 'invalid',
      'foreign_key': 'preserved',
      'settings': 99,
    });
    expect(await Preferences.loadSettings(), isNull);
    expect(
      (await SharedPreferences.getInstance()).getString('foreign_key'),
      'preserved',
    );
  });
  test('wrong preference types do not prevent startup', () async {
    SharedPreferences.setMockInitialValues({
      'schema_version': 1,
      'hidden_blocks': 99,
      'solo_block': false,
      'export_dir': 22,
      'settings': true,
    });
    expect(await Preferences.loadHiddenBlocks(), isEmpty);
    expect(await Preferences.loadSoloBlock(), isNull);
    expect(await Preferences.loadExportDirectory(), isNull);
    expect(await Preferences.loadSettings(), isNull);
  });
  test('an older file selection cannot replace a newer selection', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final source = container.read(sourceImageProvider.notifier);
    final older = source.beginImport();
    final newer = source.beginImport();
    SourceImage image(String name) =>
        SourceImage(name: name, bytes: Uint8List(0), width: 1, height: 1);
    expect(source.completeImport(older, image('old')), isFalse);
    expect(source.completeImport(newer, image('new')), isTrue);
    expect(container.read(sourceImageProvider)!.name, 'new');
    final pending = source.beginImport();
    source.clear();
    expect(source.completeImport(pending, image('late')), isFalse);
  });
}
