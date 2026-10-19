import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/project_models.dart';
import 'export.dart';
import 'file_preferences.dart';

/// Small preferences only; source images remain outside this store.
abstract final class Preferences {
  static const schemaVersion = 1;
  static FilePreferences? _file;
  static Future<void> _tail = Future.value();
  static Future<void>? _migration;
  static int _pending = 0;
  static final saving = ValueNotifier(false);
  static final error = ValueNotifier<String?>(null);
  static final _failed = <String, Future<void> Function()>{};
  static final _failures = <String, String>{};
  static String? _readError;

  static Future<void> initializeStorage(Directory directory) async {
    await flush();
    _file = FilePreferences(directory);
    try {
      await _file!.initialize();
    } on Object catch (reason) {
      _readError = '$reason';
      _refresh();
    }
  }

  static void _refresh() {
    saving.value = _pending > 0;
    error.value = _failures.isNotEmpty ? _failures.values.first : _readError;
  }

  static Future<SharedPreferences> _open() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.get('schema_version') != schemaVersion) {
      // Older/missing schema tags must not erase valid settings or locations.
      final migration = _migration ??= () async {
        if (!await prefs.setInt('schema_version', schemaVersion)) {
          throw const FileSystemException('无法保存配置版本');
        }
      }();
      try {
        await migration;
      } finally {
        if (identical(_migration, migration)) _migration = null;
      }
    }
    return prefs;
  }

  static Future<Object?> _read(String key) async {
    if (_pending > 0) await _tail;
    try {
      final result = _file == null
          ? (await _open()).get(key)
          : await _file!.read(key);
      _readError = null;
      _refresh();
      return result;
    } on Object catch (reason) {
      _readError = '$reason';
      _refresh();
      return null;
    }
  }

  static Future<void> _queue(String key, Future<void> Function() operation) {
    // An empty queue can start in the caller's zone rather than retaining an
    // already completed future from an earlier UI/test lifecycle.
    final previous = _pending == 0 ? Future<void>.value() : _tail;
    _pending++;
    _refresh();
    final future = previous.then((_) async {
      try {
        await operation();
        _failed.remove(key);
        _failures.remove(key);
      } on Object catch (reason) {
        _failed[key] = operation;
        _failures[key] = '$reason';
      } finally {
        _pending--;
        _refresh();
      }
    });
    _tail = future;
    return future;
  }

  static Future<void> _write(String key, Object? value) =>
      _queue(key, () async {
        if (_file != null) {
          await _file!.write(key, value);
          return;
        }
        final prefs = await _open();
        final success = value == null
            ? await prefs.remove(key)
            : value is List<String>
            ? await prefs.setStringList(key, value)
            : await prefs.setString(key, value as String);
        if (!success) throw const FileSystemException('设置写入失败，请检查存储权限');
      });

  static Future<void> flush() async {
    if (_pending > 0) await _tail;
    if (error.value != null) throw FileSystemException(error.value!);
  }

  static Future<void> retry() async {
    for (final entry in Map.of(_failed).entries) {
      await _queue(entry.key, entry.value);
    }
    if (_readError != null && _file != null) {
      try {
        await _file!.initialize();
        _readError = null;
      } on Object catch (reason) {
        _readError = '$reason';
      }
      _refresh();
    }
  }

  static Future<Set<String>> loadHiddenBlocks() async {
    final raw = await _read('hidden_blocks');
    return raw is List ? raw.whereType<String>().toSet() : <String>{};
  }

  static Future<void> saveHiddenBlocks(Set<String> keys) =>
      _write('hidden_blocks', keys.toList()..sort());
  static Future<String?> _string(String key) async {
    final raw = await _read(key);
    return raw is String ? raw : null;
  }

  static Future<String?> loadSoloBlock() => _string('solo_block');
  static Future<void> saveSoloBlock(String? key) => _write('solo_block', key);
  static Future<String?> loadExportDirectory() => _string('export_dir');
  static Future<void> saveExportDirectory(String? path) =>
      _write('export_dir', path);
  static Future<String?> loadThemeMode() => _string('theme_mode');
  static Future<void> saveThemeMode(String mode) => _write('theme_mode', mode);

  static Future<Map<String, bool>> loadDesktopOptions() async {
    final raw = await _string('desktop_options');
    try {
      final decoded = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
      return {
        for (final e in decoded.entries)
          if (e.value is bool) e.key: e.value as bool,
      };
    } on Object {
      return {};
    }
  }

  static Future<void> saveDesktopOptions(Map<String, bool> options) =>
      _write('desktop_options', jsonEncode(options));

  static Future<String?> loadAccessibility() => _string('accessibility');
  static Future<void> saveAccessibility(String value) =>
      _write('accessibility', value);

  static Future<ProjectSettings?> loadSettings() async {
    final raw = await _string('settings');
    if (raw == null) return null;
    try {
      return ProjectSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  static Future<void> saveSettings(ProjectSettings settings) =>
      _write('settings', jsonEncode(settings.toJson()));
  static Future<ExportOptions?> loadExportOptions() async {
    final raw = await _string('export_options');
    if (raw == null) return null;
    try {
      return ExportOptions.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  static Future<void> saveExportOptions(ExportOptions options) =>
      _write('export_options', jsonEncode(options.toJson()));
}
