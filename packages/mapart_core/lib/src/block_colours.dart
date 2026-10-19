import 'json_util.dart';

/// Turns a decoded `texture_palette_*.json` into `block id -> packed colour`.
///
/// The extractor's file lists every block it could average a texture for,
/// including ones that are not full solid cubes — a torch, a pane, a door — so
/// this is where they are dropped. What survives is a block whose top face is
/// one flat colour, which is what "a map pixel is this block's texture average"
/// requires.
///
/// [keep] is an allow-list of block ids, from `kept_blocks.json`: the folder of
/// extracted textures the user deleted from. An empty [keep] means "do not
/// filter", which is what happens before that file exists.
///
/// Where a block is listed twice, once cleanly and once with an `excluded`
/// reason, the clean entry wins: the reasons are not perfectly consistent
/// (`slime_block` and `gravel` are full cubes yet carry one), so a block that
/// also has a clean entry is one the extractor was unsure about rather than one
/// that is genuinely unusable.
Map<String, int> blockColoursFromTexturePalette(
  Map<String, dynamic> json, {
  Set<String> keep = const {},
}) {
  final fallback = <String, int>{};
  final preferred = <String, int>{};
  for (final rawBlock in asList(json['blocks'])) {
    final block = asMap(rawBlock);
    // A block the extractor could not average has no `srgb` at all, and is
    // simply not a colour rather than an error.
    final srgb = block['srgb'];
    if (srgb is! List || srgb.length != 3) continue;
    final packed =
        (asInt(srgb[0]) << 16) | (asInt(srgb[1]) << 8) | asInt(srgb[2]);
    final id = asString(block['block']);
    if (_isGlassLike(id, block['texture'])) continue;
    if (_isNotAFullCube(block)) continue;
    if (keep.isNotEmpty && !keep.contains(id)) continue;
    if (block['excluded'] == null) {
      preferred[id] = packed;
    } else {
      fallback.putIfAbsent(id, () => packed);
    }
  }
  return {...fallback, ...preferred};
}

/// Whether the extractor marked this block as anything other than a full cube,
/// or as too little texture to average.
bool _isNotAFullCube(Map<String, dynamic> block) {
  // A sprite on an empty texture — a torch, a candle, an end rod — averages to
  // whatever the few solid pixels happen to be, but the picture is mostly
  // blank, so it must not be used as a colour.
  final opaque = block['opaquePixels'];
  if (opaque is num && opaque < 200) return true;
  const unusable = {
    'notAFullCube',
    'multipart',
    'noGeometry',
    'translucent',
    'animated',
    'undecodable',
    'noTexture',
  };
  return unusable.contains(block['excluded']);
}

/// Glass and beacons have no opaque face and must never be offered as a colour.
bool _isGlassLike(String id, Object? texture) {
  if (id.contains('glass') || id == 'beacon') return true;
  return texture is String && texture.contains('glass');
}
