import 'package:meta/meta.dart';

/// A concrete Minecraft block state: a namespaced block id plus the block state
/// properties to emit.
///
/// Properties that upstream leaves out are not defaulted here; they are simply
/// absent, which means "let Minecraft use the block's default state". That is
/// what we want, because e.g. a `deepslate` with no `axis` given defaults to
/// `axis=y`, which is a full cube and the texture the map colour assumes.
@immutable
class BlockStateRef {
  const BlockStateRef(this.name, [this.properties = const <String, String>{}]);

  /// Block id as it appears upstream, e.g. `grass_block`. May or may not carry
  /// a namespace.
  final String name;

  /// Block state properties, e.g. `{'axis': 'y'}`.
  final Map<String, String> properties;

  /// Block id with an explicit namespace.
  String get namespacedId => name.contains(':') ? name : 'minecraft:$name';

  /// The canonical Sponge / Litematica block state string, e.g.
  /// `minecraft:oak_log[axis=y]`. Properties are sorted by key, which is what
  /// the Sponge schematic specification requires.
  String toBlockStateString() {
    if (properties.isEmpty) return namespacedId;
    final keys = properties.keys.toList()..sort();
    final body = keys.map((k) => '$k=${properties[k]}').join(',');
    return '$namespacedId[$body]';
  }

  /// Parses the canonical string form back into a reference.
  ///
  /// The inverse of [toBlockStateString]. Needed because the plan carries the
  /// string the export files use rather than the reference it came from, so the
  /// schematic writers have to get the properties back out of it.
  static BlockStateRef parse(String value) {
    final open = value.indexOf('[');
    if (open < 0) return BlockStateRef(value);
    final close = value.lastIndexOf(']');
    if (close < open) {
      throw FormatException('unterminated block state: $value');
    }
    final properties = <String, String>{};
    final body = value.substring(open + 1, close);
    if (body.isNotEmpty) {
      for (final pair in body.split(',')) {
        final equals = pair.indexOf('=');
        if (equals <= 0) {
          throw FormatException('bad block state property "$pair" in $value');
        }
        properties[pair.substring(0, equals)] = pair.substring(equals + 1);
      }
    }
    return BlockStateRef(value.substring(0, open), properties);
  }

  @override
  bool operator ==(Object other) =>
      other is BlockStateRef &&
      other.name == name &&
      other.properties.length == properties.length &&
      other.properties.entries.every((e) => properties[e.key] == e.value);

  @override
  int get hashCode => Object.hash(
    name,
    Object.hashAllUnordered(
      properties.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  @override
  String toString() => toBlockStateString();
}
