import 'dart:io';

import 'package:build_meow/src/data/preferences.dart';
import 'package:build_meow/src/state/project_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('failed writes remain visible and retry saves the latest settings before flush', () async {
    final root = await Directory.systemTemp.createTemp('meow-save-failure-');
    addTearDown(() => root.delete(recursive: true));
    final blocked = File('${root.path}/blocked')
      ..writeAsStringSync('not a directory');
    await Preferences.initializeStorage(Directory(blocked.path));
    await Preferences.saveSettings(const ProjectSettings(mapsX: 2));
    await Preferences.saveSettings(
      const ProjectSettings(mapsX: 5, flatMap: true),
    );
    expect(Preferences.error.value, isNotNull);
    await expectLater(Preferences.flush(), throwsA(isA<FileSystemException>()));
    await blocked.delete();
    await Preferences.retry();
    await Preferences.flush();
    expect(Preferences.error.value, isNull);
    final back = (await Preferences.loadSettings())!;
    expect(back.mapsX, 5);
    expect(back.flatMap, isTrue);
  });
}
