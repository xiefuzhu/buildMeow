// Verifies the vendored MapartCraft colour table against the authoritative
// per-version map-colour dump from cerus/minecraft-map-colors (which is
// scraped from the game's MaterialMapColor class itself).
//
// Answers two questions with evidence rather than by assumption:
//   1. Does the game have any map colour our table does not know about?
//   2. Are the 61 colours' four tones exactly what the game produces?
//
// Usage, from the mapart_core package root:
//   dart run tool/verify_colors.dart [path-to-mappings.json]
//
// The dump is expected at tool/data/mc_mapcolors.json by default:
//   curl -L https://cdn.jsdelivr.net/gh/cerus/minecraft-map-colors@main/mappings.json
import 'dart:convert';
import 'dart:io';

import 'package:mapart_core/mapart_core.dart';

void main(List<String> args) {
  final dumpPath = args.isNotEmpty ? args[0] : 'tool/data/mc_mapcolors.json';
  final dump = jsonDecode(File(dumpPath).readAsStringSync())
      as Map<String, dynamic>;

  final table = ColorTable.fromJson(
    jsonDecode(
      File('assets/colors/mapartcraft.colors.json').readAsStringSync(),
    ) as Map<String, dynamic>,
  );

  // cerus order is [180/255, 220/255, 255/255, 135/255] = dark, normal,
  // light, water. Ours is named tonesRGB.light/normal/dark/unobtainable,
  // where "light" is the base.
  List<int> unpack(int rgb) => [(rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff];

  // The versions the app actually offers. Every one must exist in the dump.
  const appVersions = [
    '1.12.2', '1.13.2', '1.14.4', '1.15.2', '1.16.5', '1.17.1', '1.18.2',
    '1.19.4', '1.20.6', '1.21.4', '1.21.8',
  ];

  var failures = 0;

  // Question 1: is our colour set complete for every offered version?
  stdout.writeln('== colour coverage ==');
  for (final version in appVersions) {
    final entry = dump[version] as Map<String, dynamic>?;
    if (entry == null) {
      stdout.writeln('  $version: NOT IN DUMP');
      failures++;
      continue;
    }
    final ids = entry.keys.map(int.parse).toList()..sort();
    // The count check has to account for the id offset too: the dump's ids
    // are 0..maxId with 0 transparent, so a version with `maxId` usable
    // colours has maxId == our colour count only from 1.17 on. Older
    // versions legitimately have fewer; what must hold is that *our* table
    // has no colour the dump lacks in the versions we target.
    final maxId = ids.last;
    final ours = table.colors.length;
    final status = maxId == ours
        ? 'OK'
        : maxId < ours
        ? 'fewer colours in-game ($maxId) — expected before 1.17'
        : 'MISMATCH (dump goes to $maxId, we have $ours)';
    if (maxId > ours) failures++;
    stdout.writeln('  $version: game has $maxId usable colours, '
        'we model $ours  $status');
  }

  // Question 2: are the tones exact, checked against every version the dump
  // has (not just the app's list — if an old version differed, someone
  // building on 1.12.2 would see it)?
  //
  // Matching is by base-colour *value*, not position: the game numbers ids
  // in MaterialMapColor order (…, 7=plant, 8=snow, 9=clay, …) while the
  // vendored table numbers its own order (…, 6=leaves, 7=clay, 8=dirt, …),
  // so a positional match misaligns from snow onwards.
  stdout.writeln('\n== tone accuracy ==');
  final versions = dump.keys.toList();
  var versionsClean = 0;
  var versionsPartial = 0;
  for (final version in versions) {
    final entry = dump[version] as Map<String, dynamic>;

    // base RGB (as int) -> dump colours [dark, normal, light, water].
    final byBase = <int, List<int>>{};
    for (final e in entry.entries) {
      if (e.key == '0') continue; // transparent air
      final item = e.value as Map<String, dynamic>;
      byBase[item['base'] as int] =
          (item['colors'] as List).cast<num>().map((n) => n.toInt()).toList();
    }

    final problems = <String>[];
    final matched = <int>{};
    for (final color in table.colors) {
      final light = color.tone(ShadeTier.bright);
      final key = (light.r << 16) | (light.g << 8) | light.b;
      final tones = byBase[key];
      if (tones == null) {
        // Not an error: versions before 1.17 genuinely have fewer colours.
        continue;
      }
      matched.add(key);
      final expected = [
        color.tone(ShadeTier.dark),
        color.tone(ShadeTier.normal),
        color.tone(ShadeTier.bright),
        color.tone(ShadeTier.water),
      ];
      for (var i = 0; i < 4; i++) {
        final actual = unpack(tones[i]);
        final e = expected[i];
        if (actual[0] != e.r || actual[1] != e.g || actual[2] != e.b) {
          problems.add('${color.name} tier $i: '
              'dump ${actual.join(',')} vs ours ${e.r},${e.g},${e.b}');
        }
      }
    }
    // Any dump colour our table does not carry, on a version where we claim
    // full coverage, is a colour the app cannot produce.
    final missing = byBase.keys
        .where((k) => !matched.contains(k))
        .map((k) => unpack(k).join(','))
        .toList();
    if (missing.isNotEmpty && byBase.length == table.colors.length) {
      problems.add('dump has colours we lack: ${missing.join(' ; ')}');
    }
    if (problems.isEmpty) {
      if (missing.isEmpty) {
        versionsClean++;
      } else {
        versionsPartial++;
      }
    } else {
      failures += problems.length;
      stdout.writeln('  $version:');
      for (final p in problems.take(6)) {
        stdout.writeln('    $p');
      }
      if (problems.length > 6) {
        stdout.writeln('    ... ${problems.length - 6} more');
      }
    }
  }
  stdout.writeln('  $versionsClean/${versions.length} versions match our table '
      'exactly, $versionsPartial match where the game has fewer colours');

  // Where did the set last change? Interesting because it bounds how old a
  // table can be before it misses a colour.
  stdout.writeln('\n== when the colour set last grew ==');
  final counts = <String, int>{};
  for (final version in versions) {
    final entry = dump[version] as Map<String, dynamic>;
    counts[version] = entry.keys.length - 1; // minus id 0
  }
  var previous = -1;
  for (final version in versions) {
    final c = counts[version]!;
    if (c != previous) {
      stdout.writeln('  $version: $c colours');
      previous = c;
    }
  }
  stdout.writeln('  (final) ${versions.last}: ${counts[versions.last]} colours');

  if (failures > 0) {
    stdout.writeln('\nFAILURES: $failures');
    exit(1);
  }
  stdout.writeln('\nall checks passed');
}
