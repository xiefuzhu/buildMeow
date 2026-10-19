import 'package:meta/meta.dart';

import 'json_util.dart';

/// A Minecraft Java Edition release we can target.
@immutable
class MinecraftVersion {
  const MinecraftVersion({
    required this.id,
    required this.dataVersion,
    required this.blockSetAlias,
    required this.minY,
    required this.maxY,
    required this.verifiedInGame,
  });

  /// Release id, e.g. `1.21.4`.
  final String id;

  /// Value written into `DataVersion` / `MinecraftDataVersion`.
  final int dataVersion;

  /// Which MapartCraft block set resolves block ids for this release.
  ///
  /// Upstream's table stops at `1.20`, so every `1.21.x` release aliases to
  /// `1.20`. That mapping has not been checked against the real 1.21 block
  /// registry — see the "未验证" section of the README.
  final String blockSetAlias;

  /// Inclusive build limits of the overworld for this release.
  final int minY;
  final int maxY;

  /// Whether anyone has loaded a file exported for this release into the game.
  /// Always `false` so far.
  final bool verifiedInGame;

  /// Number of block layers the overworld spans.
  int get height => maxY - minY + 1;

  @override
  String toString() => id;
}

/// The set of releases we can target, loaded from `assets/colors/versions.json`.
@immutable
class VersionTable {
  const VersionTable._(this.versions, this._byId);

  /// Releases in ascending order.
  final List<MinecraftVersion> versions;
  final Map<String, MinecraftVersion> _byId;

  /// The only release this build targets.
  static const String defaultVersionId = '26.1.2';

  MinecraftVersion? byId(String id) => _byId[id];

  /// Looks up [id], or throws with a helpful message.
  MinecraftVersion require(String id) {
    final version = _byId[id];
    if (version == null) {
      throw ArgumentError.value(id, 'id', 'unknown Minecraft version');
    }
    return version;
  }

  /// The newest release in the table.
  MinecraftVersion get latest => versions.last;

  factory VersionTable.fromJson(Map<String, dynamic> json) {
    final rawWorldHeight = asMap(json['worldHeight']);
    final worldHeight = rawWorldHeight.map(
      (key, value) => MapEntry(key, asMap(value)),
    );

    ({int minY, int maxY}) heightFor(String id) {
      var entry = worldHeight[id];
      // `worldHeight` is keyed by release line ("1.21"), not by every patch
      // release, so fall back to the major.minor prefix.
      if (entry == null) {
        final parts = id.split('.');
        if (parts.length >= 2) {
          entry = worldHeight['${parts[0]}.${parts[1]}'];
        }
      }
      if (entry == null) {
        throw FormatException('no world height limits recorded for $id');
      }
      return (minY: asInt(entry['minY']), maxY: asInt(entry['maxY']));
    }

    final versions = <MinecraftVersion>[];
    for (final raw in asList(json['versions'])) {
      final map = asMap(raw);
      final id = asString(map['id']);
      final height = heightFor(id);
      versions.add(
        MinecraftVersion(
          id: id,
          dataVersion: asInt(map['dataVersion']),
          blockSetAlias: asString(map['blockSetAlias']),
          minY: height.minY,
          maxY: height.maxY,
          verifiedInGame: asBool(map['verifiedInGame']),
        ),
      );
    }

    return VersionTable._(List.unmodifiable(versions), {
      for (final v in versions) v.id: v,
    });
  }
}
