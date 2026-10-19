import 'dart:convert';
import 'dart:io';

import 'package:build_meow/src/data/file_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('meow-prefs-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'legacy settings and export location migrate without deleting the source',
    () async {
      final legacy = File('${directory.path}/shared_preferences.json');
      await legacy.writeAsString(
        jsonEncode({
          'flutter.settings': '{"flatMap":true}',
          'flutter.export_dir': r'C:\art',
          'flutter.theme_mode': 'dark',
        }),
      );
      final store = FilePreferences(directory);
      await store.initialize();
      expect(await store.read('export_dir'), r'C:\art');
      expect(await store.read('settings'), '{"flatMap":true}');
      expect(await store.read('theme_mode'), 'dark');
      expect(await legacy.exists(), isTrue);
    },
  );

  test(
    'fresh instances merge writes and read the current disk state',
    () async {
      final first = FilePreferences(directory);
      final second = FilePreferences(directory);
      await first.write('theme_mode', 'dark');
      await second.write('export_dir', r'C:\exports');
      await first.write('settings', '{"mapsX":2}');
      final restarted = FilePreferences(directory);
      expect(await restarted.read('theme_mode'), 'dark');
      expect(await restarted.read('export_dir'), r'C:\exports');
      expect(await second.read('settings'), '{"mapsX":2}');
      await restarted.write('theme_mode', null);
      expect(await first.read('theme_mode'), isNull);
      expect(await first.read('export_dir'), r'C:\exports');
    },
  );

  test('concurrent store instances leave complete valid JSON and no temporary files', () async {
    await Future.wait([
      for (var i = 0; i < 6; i++)
        FilePreferences(directory).write('key$i', 'value$i'),
    ]);
    final store = FilePreferences(directory);
    for (var i = 0; i < 6; i++) {
      expect(await store.read('key$i'), 'value$i');
    }
    final json = jsonDecode(
      await File('${directory.path}/preferences.json').readAsString(),
    ) as Map;
    expect((json['values'] as Map).length, 6);
    expect(
      await directory.list().where((f) => f.path.endsWith('.tmp')).isEmpty,
      isTrue,
    );
  });
}
