import 'dart:convert';
import 'dart:io';

/// A stable Windows store, independent of the executable's location and of
/// SharedPreferences' per-process cache. Each write merges the latest file.
class FilePreferences {
  FilePreferences(this.directory);
  final Directory directory;
  int _sequence = 0;

  Future<T> _locked<T>(
    Future<T> Function(Map<String, dynamic>) action, {
    bool write = false,
  }) async {
    await directory.create(recursive: true);
    final lock = await File('${directory.path}/preferences.lock')
        .open(mode: FileMode.append);
    var acquired = false;
    try {
      await lock.lock(FileLock.blockingExclusive);
      acquired = true;
      final file = File('${directory.path}/preferences.json');
      final exists = await file.exists();
      Map<String, dynamic> values = {};
      if (exists) {
        final decoded =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        values = Map<String, dynamic>.from(decoded['values'] as Map);
      } else {
        final legacy = File('${directory.path}/shared_preferences.json');
        if (await legacy.exists()) {
          final decoded =
              jsonDecode(await legacy.readAsString()) as Map<String, dynamic>;
          values = {
            for (final entry in decoded.entries)
              if (entry.key.startsWith('flutter.'))
                entry.key.substring(8): entry.value,
          };
        }
      }
      final result = await action(values);
      if (write || !exists) {
        final temporary = File('${file.path}.$pid.${_sequence++}.tmp');
        try {
          await temporary.writeAsString(
            jsonEncode({'schemaVersion': 1, 'values': values}),
            flush: true,
          );
          await temporary.rename(file.path);
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      }
      return result;
    } finally {
      if (acquired) await lock.unlock();
      await lock.close();
    }
  }

  Future<void> initialize() => _locked((_) async {});
  Future<Object?> read(String key) => _locked((values) async => values[key]);
  Future<void> write(String key, Object? value) => _locked((values) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }, write: true);
}
