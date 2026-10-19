import 'package:meta/meta.dart';

import 'json_util.dart';

/// Block id to Simplified Chinese name, from Minecraft's own `zh_cn` language
/// file. See `assets/lang/NOTICE.md` for provenance.
///
/// The names are only ever printed. Everything written to disk — the material
/// list's id column, the schematic palette, the Litematica block state palette
/// — keeps the English id, because that is what the game reads.
@immutable
class BlockNames {
  const BlockNames._(this._names, this._blockIds);

  final Map<String, String> _names;

  /// Which ids the table knows, so a caller can tell "no Chinese name" from
  /// "the name is the id".
  final Set<String> _blockIds;

  static const BlockNames empty = BlockNames._(<String, String>{}, <String>{});

  int get length => _names.length;

  bool knows(String blockId) => _blockIds.contains(blockId);

  /// The Chinese name for [blockId], or `null` when the language file has none.
  ///
  /// Two blocks the palette can reach have no Chinese name because they are
  /// entities rather than blocks — an item frame is `entity.minecraft.
  /// item_frame` — and a caller that gets `null` should fall back to the
  /// English display name.
  String? zh(String blockId) => _names[blockId];

  /// The Chinese name for [blockId], or [fallback] — the English display name —
  /// when there is none.
  String zhOr(String blockId, String fallback) => _names[blockId] ?? fallback;

  factory BlockNames.fromJson(Map<String, dynamic> json) {
    final raw = asMap(json['blocks']);
    return BlockNames._(
      Map.unmodifiable(raw.map((id, name) => MapEntry(id, asString(name)))),
      Set.unmodifiable(raw.keys),
    );
  }

  /// Merges two tables, [other] winning on a conflict. Unused so far; kept
  /// because a second language file is the obvious next thing to add.
  BlockNames merge(BlockNames other) => BlockNames._(
    Map.unmodifiable({..._names, ...other._names}),
    Set.unmodifiable({..._blockIds, ...other._blockIds}),
  );
}
