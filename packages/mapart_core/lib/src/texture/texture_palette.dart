import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:meta/meta.dart';

import '../block_state_ref.dart';
import '../json_util.dart';
import '../lab.dart';
import '../rgb.dart';
import 'block_face.dart';

/// Why a block was left out of the palette.
///
/// The first group comes out of the jar's own data and is decided while
/// extracting; [falling], [emissive], [noisy] and [duplicate] are decided while
/// selecting, and the user can override every one of them.
enum ExclusionReason {
  /// Geometry is not a single 16x16x16 cube: buttons, doors, fences, plants.
  notAFullCube,

  /// The blockstate is built from `multipart` parts, so there is no single
  /// model to read a face from. Fences, walls, shelves.
  multipart,

  /// The model resolves to no geometry at all: signs, air.
  noGeometry,

  /// The texture has partial alpha, or is entirely transparent. Glass, ice,
  /// copper grates — none of them show their own colour on a map.
  translucent,

  /// The texture is animated (it has a `.png.mcmeta` beside it). A still
  /// average of frame one is not what the block looks like.
  animated,

  /// A face carries a `tintindex`, so the game paints it with a biome or
  /// foliage colour instead of the texture as authored. Grass tops, leaves.
  biomeTinted,

  /// The block's appearance depends on which way it faces, or the model is a
  /// pattern: glazed terracotta, pistons, furnaces, crafting tables.
  patterned,

  /// A face texture reference that resolves to nothing in the jar.
  noTexture,

  /// The PNG would not decode.
  undecodable,

  /// A gravity block: sand, gravel, concrete powder. They fall, so a build out
  /// of them has to be supported. Off by default, switchable on.
  falling,

  /// A block that emits light, so it will not read as its texture's colour in
  /// a lit room. Off by default, switchable on.
  emissive,

  /// Above the noisiness threshold.
  noisy,

  /// A near-duplicate of a block already in the palette.
  duplicate,
}

/// One block the extractor looked at, usable or not.
@immutable
class TexturePaletteEntry {
  const TexturePaletteEntry({
    required this.blockId,
    required this.state,
    required this.texture,
    required this.face,
    required this.average,
    this.excluded,
    this.pixels,
    this.pixelWidth = 0,
    this.pixelHeight = 0,
  });

  /// Block id without a namespace, e.g. `oak_planks`.
  final String blockId;

  /// The block state to place. Taken from the blockstate variant that was read,
  /// so an `oak_log` comes back as `axis=y` — the orientation whose top face is
  /// the end grain.
  final BlockStateRef state;

  /// The texture the average came from, e.g. `block/oak_planks`.
  final String texture;

  /// Which face was read.
  final BlockFace face;

  /// The averaged colour, or `null` when the block never got that far.
  final AverageColor? average;

  /// Non-null when the extractor rejected the block.
  final ExclusionReason? excluded;

  /// The face texture, RGBA. Only filled when extraction was asked to keep
  /// pixels. A tall animated strip is cropped to its first frame.
  final Uint8List? pixels;
  final int pixelWidth;
  final int pixelHeight;

  /// Stable identity for the UI's per-block switches.
  String get key => state.toBlockStateString();

  /// The block's name for display: `Oak Planks`.
  String get displayName {
    final words = blockId.split('_');
    return words
        .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  bool get extractorAccepted => excluded == null && average != null;

  @override
  String toString() =>
      'TexturePaletteEntry($blockId, $face, '
      '${average?.srgb}, excluded: $excluded)';
}

/// Everything the extractor found in one jar, before the user's thresholds.
@immutable
class TexturePalette {
  const TexturePalette({
    required this.entries,
    required this.source,
    required this.face,
    required this.elapsed,
  });

  /// Every blockstate examined, ordered by block id. Rejected blocks are in
  /// here too, with their [ExclusionReason], so the UI can list them and let
  /// the user switch them back on.
  final List<TexturePaletteEntry> entries;

  /// What the entries came from, for the UI and the cache key.
  final String source;

  final BlockFace face;

  /// How long the extraction took, which is the number worth reporting: it runs
  /// once per jar and everything after it reads the cache.
  final Duration elapsed;

  /// Blocks that got as far as an average colour.
  List<TexturePaletteEntry> get accepted =>
      entries.where((e) => e.extractorAccepted).toList(growable: false);

  /// How many blocks fell to each reason.
  Map<ExclusionReason, int> get exclusionCounts {
    final counts = <ExclusionReason, int>{};
    for (final entry in entries) {
      final reason = entry.excluded;
      if (reason == null) continue;
      counts[reason] = (counts[reason] ?? 0) + 1;
    }
    return counts;
  }

  /// Finds an entry by its [TexturePaletteEntry.key].
  TexturePaletteEntry? entryFor(String key) {
    for (final entry in entries) {
      if (entry.key == key) return entry;
    }
    return null;
  }
}

/// The knobs on the selection step.
///
/// Kept apart from the extraction so that moving a slider re-filters a palette
/// that is already in memory instead of reading the jar again.
@immutable
class TexturePaletteOptions {
  const TexturePaletteOptions({
    this.applyFaceBrightness = false,
    this.maxNoisiness = 24,
    this.dedupeDistance = 4,
    this.includeFalling = false,
    this.includeEmissive = false,
    this.includePatterned = false,
    this.forceInclude = const <String>{},
    this.forceExclude = const <String>{},
  });

  /// Multiply each colour by the game's per-face brightness.
  ///
  /// Off by default: the palette is built from one face and used on the same
  /// face, so no correction is needed. It is there for building a wall from top
  /// faces, where the game will shade every pixel as a side.
  final bool applyFaceBrightness;

  /// Textures above this luminance deviation are dropped. Concrete sits near
  /// 1, cobblestone near 29 and glowstone near 63.
  final double maxNoisiness;

  /// Lab distance under which two blocks count as the same colour. The flatter
  /// of the pair is kept.
  final double dedupeDistance;

  final bool includeFalling;
  final bool includeEmissive;

  /// Whether to ignore the extractor's "patterned" rejection.
  final bool includePatterned;

  /// Keys the user switched back on by hand, whatever the reason.
  final Set<String> forceInclude;

  /// Keys the user switched off by hand.
  final Set<String> forceExclude;
}

/// A block the palette can actually use, ready for colour matching.
@immutable
class PaletteBlock {
  const PaletteBlock({
    required this.entry,
    required this.color,
    required this.linear,
    required this.noisiness,
  });

  final TexturePaletteEntry entry;

  /// The colour to match against, after any face-brightness correction.
  final Rgb color;

  /// The same colour in linear light.
  final LinearRgb linear;

  final double noisiness;

  String get key => entry.key;
  String get blockId => entry.blockId;
  String get displayName => entry.displayName;
  String get texture => entry.texture;

  @override
  String toString() => 'PaletteBlock(${entry.blockId}, $color)';
}

/// Extracts a palette from a Minecraft client jar.
///
/// Reads the blockstate, block model and texture PNGs out of
/// `assets/minecraft/` and averages each block's [BlockFace] texture. Nothing
/// is bundled with the app; the jar is the user's own game file.
///
/// Written against a real jar rather than from the format description, and the
/// details that mattered are noted where they bite:
///
/// * a face texture, and a `textures` map value, may be either a string or an
///   object like `{"sprite": "block/x", "force_translucent": true}`;
/// * references may carry a namespace (`minecraft:block/oak_log`);
/// * `parent` chains go through `block/cube`, `block/cube_all`,
///   `block/cube_column` and friends, and the child's `textures` override the
///   parent's.
TexturePalette extractTexturePalette(
  Uint8List jarBytes, {
  required String source,
  BlockFace face = BlockFace.up,
  bool keepPixels = false,
}) {
  final watch = Stopwatch()..start();
  final archive = ZipDecoder().decodeBytes(jarBytes);

  final entries = <String, ArchiveFile>{};
  for (final file in archive) {
    if (file.isFile) entries[file.name] = file;
  }

  final models = <String, Map<String, dynamic>?>{};
  final entriesOut = <TexturePaletteEntry>[];

  final statePaths =
      entries.keys
          .where(
            (n) =>
                n.startsWith('assets/minecraft/blockstates/') &&
                n.endsWith('.json'),
          )
          .toList()
        ..sort();

  for (final statePath in statePaths) {
    final blockId = statePath
        .substring('assets/minecraft/blockstates/'.length)
        .replaceAll('.json', '');
    entriesOut.add(
      _extractBlock(
        blockId: blockId,
        statePath: statePath,
        entries: entries,
        models: models,
        face: face,
        keepPixels: keepPixels,
      ),
    );
  }

  return TexturePalette(
    entries: List.unmodifiable(entriesOut),
    source: source,
    face: face,
    elapsed: watch.elapsed,
  );
}

TexturePaletteEntry _extractBlock({
  required String blockId,
  required String statePath,
  required Map<String, ArchiveFile> entries,
  required Map<String, Map<String, dynamic>?> models,
  required BlockFace face,
  bool keepPixels = false,
}) {
  // The verdict is accumulated rather than returned on the spot, because the
  // user is allowed to switch a rejected block back on and that needs its
  // colour. Only where no texture can be reached at all does a block end up
  // with no average, and only then can it not be switched back on.
  ExclusionReason? reason;
  void fail(ExclusionReason r) => reason ??= r;

  TexturePaletteEntry finish({
    String texture = '',
    AverageColor? average,
    BlockStateRef? state,
    Uint8List? pixels,
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) => TexturePaletteEntry(
    blockId: blockId,
    state: state ?? BlockStateRef(blockId),
    texture: texture,
    face: face,
    average: average,
    excluded: reason,
    pixels: pixels,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
  );

  final stateBytes = entries[statePath]!.readBytes();
  if (stateBytes == null) {
    return finish();
  }

  Object? stateJson;
  try {
    stateJson = jsonDecode(utf8.decode(stateBytes));
  } on FormatException {
    return finish();
  }
  if (stateJson is! Map) return finish();
  final state = stateJson.cast<String, dynamic>();

  // Which variant to read. A `multipart` block has no single model, so the
  // first part stands in for it: enough to give the user a colour to switch
  // back on, and flagged all the same.
  String? modelRef;
  var variantKey = '';
  final rawVariants = state['variants'];
  if (rawVariants != null) {
    final variants = asMap(rawVariants);
    if (variants.isEmpty) return finish();

    // A block whose variants are keyed by a direction looks different depending
    // on which way it was placed, so one palette entry for it would be a lie
    // for most placements.
    if (variants.keys.any((k) => k.contains('facing='))) {
      fail(ExclusionReason.patterned);
    }

    final variant = _pickVariant(variants);
    variantKey = variant.key;
    final raw = variant.value['model'];
    if (raw is String) modelRef = raw;
  } else {
    final parts = state['multipart'];
    if (parts is! List) return finish();
    fail(ExclusionReason.multipart);
    for (final part in parts) {
      final applied = asMap(part)['apply'];
      final model = applied is List
          ? asMap(asList(applied).first)['model']
          : asMap(applied)['model'];
      if (model is String) {
        modelRef = model;
        break;
      }
    }
  }
  if (modelRef == null) return finish();

  final resolved = _resolveModel(modelRef, entries, models);
  if (resolved == null || resolved.elements.isEmpty) {
    fail(ExclusionReason.noGeometry);
    return finish();
  }

  // A full solid cube is one element spanning the whole block with all six
  // faces. Failing that, the first element that has the face at all is read, so
  // the block still gets a colour.
  Map<String, dynamic>? cube;
  for (final element in resolved.elements) {
    final from = element['from'];
    final to = element['to'];
    if (from is List &&
        to is List &&
        from.length == 3 &&
        to.length == 3 &&
        from.every((v) => v is num && v == 0) &&
        to.every((v) => v is num && v == 16)) {
      cube = element;
      break;
    }
  }
  if (cube == null) fail(ExclusionReason.notAFullCube);
  if (resolved.elements.length > 1) {
    // An overlay drawn over the cube: grass block, slime, honey, spawner.
    fail(ExclusionReason.patterned);
  }

  Map<String, dynamic>? readable;
  for (final element in <Map<String, dynamic>>[?cube, ...resolved.elements]) {
    final faces = element['faces'];
    if (faces is Map && faces.containsKey(face.key)) {
      readable = element;
      break;
    }
  }
  if (readable == null) {
    fail(ExclusionReason.noGeometry);
    return finish();
  }

  final faces = asMap(readable['faces']);
  if (cube != null) {
    for (final required in BlockFace.values) {
      if (!faces.containsKey(required.key)) {
        fail(ExclusionReason.notAFullCube);
        break;
      }
    }
  }

  // If the four sides do not resolve to one texture the block has a distinct
  // front: a crafting table, a furnace, an observer. The references have to be
  // resolved through the texture map first — `cube_all` gives every side a
  // different `#name` that all resolve to the same texture.
  if (faces.keys.toSet().containsAll(BlockFace.horizontal.map((f) => f.key))) {
    final resolvedSides = <String>{};
    for (final side in BlockFace.horizontal) {
      final sideTexture = _resolveTexture(
        asMap(faces[side.key])['texture'],
        resolved.textures,
      );
      if (sideTexture == null) {
        fail(ExclusionReason.noTexture);
        break;
      }
      resolvedSides.add(sideTexture.path);
    }
    if (resolvedSides.length > 1) fail(ExclusionReason.patterned);
  }

  // A rotated UV is how a model makes a pattern out of one texture, which is
  // what glazed terracotta is.
  for (final rawFace in faces.values) {
    if (asMap(rawFace).containsKey('rotation')) {
      fail(ExclusionReason.patterned);
      break;
    }
  }

  final chosen = asMap(faces[face.key]);
  if (chosen.containsKey('tintindex')) fail(ExclusionReason.biomeTinted);

  final resolvedTexture = _resolveTexture(chosen['texture'], resolved.textures);
  if (resolvedTexture == null) {
    fail(ExclusionReason.noTexture);
    return finish();
  }
  if (resolvedTexture.forceTranslucent) fail(ExclusionReason.translucent);

  final pngPath = 'assets/minecraft/textures/${resolvedTexture.path}.png';
  final png = entries[pngPath];
  if (png == null) {
    fail(ExclusionReason.noTexture);
    return finish(texture: resolvedTexture.path);
  }
  final animated = entries.containsKey('$pngPath.mcmeta');
  if (animated) fail(ExclusionReason.animated);

  final pngBytes = png.readBytes();
  final decoded = pngBytes == null ? null : img.decodePng(pngBytes);
  if (decoded == null) {
    fail(ExclusionReason.undecodable);
    return finish(texture: resolvedTexture.path);
  }

  // Two decoding traps, handled without converting the image.
  //
  // `image` hands back a greyscale PNG as a one-channel image whose pixel
  // accessor puts the grey in `r` and leaves `g` and `b` at zero, so `stone`
  // averages to (126, 0, 0) rather than (126, 126, 126). The grey is replicated
  // rather than run through `convert`, which was tried and mangled indexed
  // PNGs — `lime_concrete` came out black.
  //
  // And `image` reports alpha 0 for a PNG with no alpha channel at all, which
  // would make every opaque texture look fully transparent. The channel count
  // says whether there is an alpha channel to believe.
  final isGrey = decoded.numChannels == 1;
  final hasAlpha = decoded.numChannels >= 4;
  final rgba = Uint8List(decoded.width * decoded.height * 4);
  var offset = 0;
  for (var y = 0; y < decoded.height; y++) {
    for (var x = 0; x < decoded.width; x++) {
      final p = decoded.getPixel(x, y);
      final r = p.r.toInt().clamp(0, 255);
      rgba[offset++] = r;
      rgba[offset++] = isGrey ? r : p.g.toInt().clamp(0, 255);
      rgba[offset++] = isGrey ? r : p.b.toInt().clamp(0, 255);
      rgba[offset++] = hasAlpha ? p.a.toInt().clamp(0, 255) : 255;
    }
  }

  Uint8List? pixels;
  var pixelWidth = 0;
  var pixelHeight = 0;
  if (keepPixels && decoded.width > 0) {
    final side = decoded.width;
    final frameHeight = decoded.height >= side ? side : decoded.height;
    pixels = Uint8List(side * frameHeight * 4);
    for (var y = 0; y < frameHeight; y++) {
      final from = y * decoded.width * 4;
      pixels.setRange(y * side * 4, (y + 1) * side * 4, rgba, from);
    }
    pixelWidth = side;
    pixelHeight = frameHeight;
  }
  // An animated strip is many frames stacked. Averaging all of them is not
  // the colour of the block, so those stay excluded; the first frame is kept
  // only for the preview.
  if (animated) {
    return finish(
      texture: resolvedTexture.path,
      pixels: pixels,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      state: _stateFromVariantKey(blockId, variantKey),
    );
  }

  if (hasPartialAlpha(rgba)) fail(ExclusionReason.translucent);
  final average = averageTexture(rgba, decoded.width, decoded.height);
  if (average == null) {
    fail(ExclusionReason.translucent);
    return finish(
      texture: resolvedTexture.path,
      pixels: pixels,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
  }

  // Gravity and light emission are behaviour, not assets, so they cannot be
  // read out of the jar. Flagged rather than dropped: the colour is real, the
  // user just has to say they want it.
  if (kFallingBlocks.contains(blockId)) {
    fail(ExclusionReason.falling);
  } else if (kEmissiveBlocks.contains(blockId)) {
    fail(ExclusionReason.emissive);
  }

  return finish(
    texture: resolvedTexture.path,
    average: average,
    state: _stateFromVariantKey(blockId, variantKey),
    pixels: pixels,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
  );
}

/// The variant to read a face from, with the key it came from.
///
/// The plain variant if there is one, then an upright `axis=y` (a log's end
/// grain is its top face, and that is what you see lying the build down), then
/// whatever comes first. The variant's own `x`/`y` rotation is deliberately
/// *not* applied: it is a cosmetic model rotation and would make the answer
/// depend on which of several equivalent variants the JSON happened to list
/// first.
({String key, Map<String, dynamic> value}) _pickVariant(
  Map<String, dynamic> variants,
) {
  for (final key in <String>['', 'axis=y']) {
    final value = variants[key];
    if (value != null) return (key: key, value: _firstVariant(value));
  }
  final first = variants.entries.first;
  return (key: first.key, value: _firstVariant(first.value));
}

Map<String, dynamic> _firstVariant(Object? value) {
  if (value is List) {
    if (value.isEmpty) return const <String, dynamic>{};
    return asMap(value.first);
  }
  return asMap(value);
}

/// Turns a blockstate variant key like `axis=y` into a block state.
BlockStateRef _stateFromVariantKey(String blockId, String raw) {
  if (raw.isEmpty) return BlockStateRef(blockId);
  final properties = <String, String>{};
  for (final part in raw.split(',')) {
    final eq = part.indexOf('=');
    if (eq <= 0) continue;
    properties[part.substring(0, eq)] = part.substring(eq + 1);
  }
  return BlockStateRef(blockId, properties);
}

@immutable
class _ResolvedModel {
  const _ResolvedModel(this.textures, this.elements);
  final Map<String, Object?> textures;
  final List<Map<String, dynamic>> elements;
}

/// Flattens a `parent` chain, child overriding parent.
_ResolvedModel? _resolveModel(
  String reference,
  Map<String, ArchiveFile> entries,
  Map<String, Map<String, dynamic>?> models,
) {
  final textures = <String, Object?>{};
  var elements = const <Map<String, dynamic>>[];
  final seen = <String>{};

  var current = _stripNamespace(reference);
  while (true) {
    if (!seen.add(current)) break;
    if (!models.containsKey(current)) {
      final bytes = entries['assets/minecraft/models/$current.json']
          ?.readBytes();
      if (bytes == null) {
        models[current] = null;
      } else {
        try {
          final decoded = jsonDecode(utf8.decode(bytes));
          models[current] = decoded is Map
              ? decoded.cast<String, dynamic>()
              : null;
        } on FormatException {
          models[current] = null;
        }
      }
    }
    final model = models[current];
    if (model == null) break;

    for (final entry in asMap(
      model['textures'] ?? const <String, dynamic>{},
    ).entries) {
      // The child's declaration wins, so only fill in what is not set yet.
      textures.putIfAbsent(entry.key, () => entry.value);
    }
    final rawElements = model['elements'];
    // The child wins, and the walk goes child to root, so only the first
    // model that declares geometry counts.
    if (rawElements is List && elements.isEmpty) {
      elements = rawElements.map(asMap).toList(growable: false);
    }

    final parent = model['parent'];
    if (parent is! String) break;
    current = _stripNamespace(parent);
  }

  return _ResolvedModel(textures, elements);
}

@immutable
class _ResolvedTexture {
  const _ResolvedTexture(this.path, this.forceTranslucent);
  final String path;
  final bool forceTranslucent;
}

/// Follows `#ref` indirections to a concrete texture path.
///
/// A reference, and the `textures` map value it points at, can each be a string
/// or an object. Newer jars use the object form with `force_translucent` for
/// things like stained glass.
_ResolvedTexture? _resolveTexture(
  Object? reference,
  Map<String, Object?> textures,
) {
  var value = reference;
  var forced = false;

  for (var hop = 0; hop < 16; hop++) {
    if (value is Map) {
      final map = value.cast<String, dynamic>();
      if (map['force_translucent'] == true) forced = true;
      value = map['sprite'];
      if (value == null) return null;
      continue;
    }
    if (value is! String) return null;
    if (!value.startsWith('#')) {
      return _ResolvedTexture(_stripNamespace(value), forced);
    }
    final key = value.substring(1);
    if (!textures.containsKey(key)) return null;
    value = textures[key];
  }
  return null;
}

String _stripNamespace(String value) {
  final colon = value.indexOf(':');
  return colon < 0 ? value : value.substring(colon + 1);
}

/// Full solid cubes that fall, so a build out of them has to be supported.
///
/// Not derivable from the jar: gravity is behaviour, not assets. Curated.
final Set<String> kFallingBlocks = <String>{
  'sand',
  'red_sand',
  'gravel',
  'suspicious_sand',
  'suspicious_gravel',
  ...<String>{
    for (final colour in <String>[
      'white',
      'orange',
      'magenta',
      'light_blue',
      'yellow',
      'lime',
      'pink',
      'gray',
      'light_gray',
      'cyan',
      'purple',
      'blue',
      'brown',
      'green',
      'red',
      'black',
    ])
      '${colour}_concrete_powder',
  },
};

/// Full solid cubes that emit light, so they will not read as their texture.
///
/// Also not derivable from the jar. Curated, and deliberately short: only the
/// full-cube light sources.
const Set<String> kEmissiveBlocks = <String>{
  'magma_block',
  'glowstone',
  'sea_lantern',
  'shroomlight',
  'redstone_lamp',
  'jack_o_lantern',
  'ochre_froglight',
  'verdant_froglight',
  'pearlescent_froglight',
  'crying_obsidian',
};

/// Applies the user's thresholds to an extracted palette.
///
/// Split from [extractTexturePalette] on purpose: this is cheap and runs every
/// time a slider moves, while the extraction reads a 30 MB jar and runs once.
List<PaletteBlock> selectPaletteBlocks(
  TexturePalette palette,
  TexturePaletteOptions options,
) {
  final accepted = <PaletteBlock>[];
  final rejected = <String, ExclusionReason>{};

  for (final entry in palette.entries) {
    final average = entry.average;
    final key = entry.key;

    if (options.forceExclude.contains(key)) continue;
    if (average == null) {
      if (options.forceInclude.contains(key)) {
        // Nothing to include: there is no colour.
      }
      continue;
    }

    final forced = options.forceInclude.contains(key);
    if (!forced) {
      final reason = entry.excluded;
      if (reason != null) {
        final overridable = switch (reason) {
          ExclusionReason.falling => options.includeFalling,
          ExclusionReason.emissive => options.includeEmissive,
          ExclusionReason.patterned => options.includePatterned,
          _ => false,
        };
        if (!overridable) {
          rejected[key] = reason;
          continue;
        }
      }
      if (average.noisiness > options.maxNoisiness) {
        rejected[key] = ExclusionReason.noisy;
        continue;
      }
    }

    accepted.add(_toPaletteBlock(entry, options));
  }

  return _dedupe(accepted, options, rejected);
}

PaletteBlock _toPaletteBlock(
  TexturePaletteEntry entry,
  TexturePaletteOptions options,
) {
  final average = entry.average!;
  if (!options.applyFaceBrightness) {
    return PaletteBlock(
      entry: entry,
      color: average.srgb,
      linear: average.linear,
      noisiness: average.noisiness,
    );
  }

  // The game multiplies a face's light by a fixed factor, so the correction
  // belongs in linear light rather than on the 8-bit value.
  final factor = entry.face.brightness;
  final linear = LinearRgb(
    average.linear.r * factor,
    average.linear.g * factor,
    average.linear.b * factor,
  );
  return PaletteBlock(
    entry: entry,
    color: Rgb(
      (linearToSrgb(linear.r) * 255).round().clamp(0, 255),
      (linearToSrgb(linear.g) * 255).round().clamp(0, 255),
      (linearToSrgb(linear.b) * 255).round().clamp(0, 255),
    ),
    linear: linear,
    noisiness: average.noisiness,
  );
}

/// Keeps one block per near-identical colour, preferring the flattest.
///
/// Two blocks whose averages are within [TexturePaletteOptions.dedupeDistance]
/// are the same colour to the eye, and the speckled one of the pair tiles into
/// visible noise, so the flatter one wins.
List<PaletteBlock> _dedupe(
  List<PaletteBlock> blocks,
  TexturePaletteOptions options,
  Map<String, ExclusionReason> rejected,
) {
  if (options.dedupeDistance <= 0) return blocks;

  final byFlattest = [...blocks]
    ..sort((a, b) {
      final byNoise = a.noisiness.compareTo(b.noisiness);
      return byNoise != 0 ? byNoise : a.blockId.compareTo(b.blockId);
    });

  final kept = <PaletteBlock>[];
  final labs = <Lab>[];
  for (final block in byFlattest) {
    final lab = Lab.fromRgb(block.color.r, block.color.g, block.color.b);
    var duplicate = false;
    for (var i = 0; i < labs.length; i++) {
      if (labs[i].distanceTo(lab) < options.dedupeDistance) {
        duplicate = true;
        break;
      }
    }
    if (duplicate) {
      rejected[block.key] = ExclusionReason.duplicate;
      continue;
    }
    labs.add(lab);
    kept.add(block);
  }

  // Back to a stable, readable order: by colour, lightest first.
  kept.sort((a, b) {
    final byL = Lab.fromRgb(
      b.color.r,
      b.color.g,
      b.color.b,
    ).l.compareTo(Lab.fromRgb(a.color.r, a.color.g, a.color.b).l);
    return byL != 0 ? byL : a.blockId.compareTo(b.blockId);
  });
  return kept;
}

/// Sorts blocks by hue, then by lightness, for the palette list.
List<PaletteBlock> sortByHue(Iterable<PaletteBlock> blocks) {
  final out = blocks.toList();
  out.sort((a, b) {
    final la = Lab.fromRgb(a.color.r, a.color.g, a.color.b);
    final lb = Lab.fromRgb(b.color.r, b.color.g, b.color.b);
    final ha = math.atan2(la.b, la.a);
    final hb = math.atan2(lb.b, lb.a);
    final byHue = ha.compareTo(hb);
    return byHue != 0 ? byHue : lb.l.compareTo(la.l);
  });
  return out;
}
