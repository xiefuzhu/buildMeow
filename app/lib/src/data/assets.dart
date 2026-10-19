import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:mapart_core/mapart_core.dart';

/// Loads the vendored colour table and version list out of the `mapart_core`
/// package's assets.
///
/// Core declares these under its own `flutter:` section, so Flutter exposes them
/// with a `packages/mapart_core/` prefix. The same files are read from disk by
/// core's own `dart test`, which is why they live in the package rather than in
/// the app.
abstract final class MapartAssets {
  static const String _prefix = 'packages/mapart_core/assets/colors';
  static const String _langPrefix = 'packages/mapart_core/assets/lang';

  static Future<ColorTable> loadColorTable() async {
    final raw = await rootBundle.loadString('$_prefix/mapartcraft.colors.json');
    final catalog = await rootBundle.loadString(
      '$_prefix/block_map_colors.json',
    );
    return ColorTable.fromJson(jsonDecode(raw) as Map<String, dynamic>)
        .includingGameBlocks(
          jsonDecode(catalog) as Map<String, dynamic>,
          '26.1.2',
        );
  }

  static Future<BlockCapabilities> loadBlockCapabilities() async {
    final raw = await rootBundle.loadString('$_prefix/block_capabilities.json');
    return BlockCapabilities.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  static Future<VersionTable> loadVersionTable() async {
    final raw = await rootBundle.loadString('$_prefix/versions.json');
    return VersionTable.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Each block's own colour, packed `0xRRGGBB`, from the 26.1.2 texture
  /// averages. A block the extractor could not colour is absent, and the
  /// palette keeps the shared map colour for it.
  ///
  /// The filtering — full solid cubes only, no glass, no sprites — lives in
  /// core's `blockColoursFromTexturePalette`, so the app and core's own tools
  /// cannot disagree about which blocks are on the palette.
  static Future<Map<String, int>> loadBlockColors() async {
    final raw = await rootBundle.loadString(
      '$_prefix/texture_palette_26_1_2.json',
    );
    return blockColoursFromTexturePalette(
      jsonDecode(raw) as Map<String, dynamic>,
      keep: await _keptBlocks(),
    );
  }

  /// Face textures packed into one image, plus the block id of each cell.
  static Future<({Uint8List png, Map<String, int> index, int cell})>
  loadBlockTextures() async {
    final data = await rootBundle.load('$_prefix/block_textures.png');
    final raw = await rootBundle.loadString('$_prefix/block_textures.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final blocks = json['blocks'] as Map<String, dynamic>;
    final kept = await _keptBlocks();
    final index = <String, int>{};
    for (final entry in blocks.entries) {
      if (_isGlassLike(entry.key, null)) continue;
      if (kept.isNotEmpty && !kept.contains(entry.key)) continue;
      index[entry.key] = (entry.value as num).toInt();
    }
    return (
      png: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      index: index,
      cell: (json['cell'] as num).toInt(),
    );
  }

  /// The Chinese name of each block, for the interface and the blueprint
  /// sheets. Export files still name blocks by their English id.
  static Future<BlockNames> loadBlockNames() async {
    final raw = await rootBundle.loadString('$_langPrefix/zh_cn_blocks.json');
    return BlockNames.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }
}

bool _isGlassLike(String id, Object? texture) {
  if (id.contains('glass') || id == 'beacon') return true;
  return texture is String && texture.contains('glass');
}

/// Block ids the user kept when they cleaned `方块贴图`. Empty if that file has
/// not been written yet, which means "do not filter".
Future<Set<String>> _keptBlocks() async {
  try {
    final raw = await rootBundle.loadString(
      'packages/mapart_core/assets/colors/kept_blocks.json',
    );
    final list = jsonDecode(raw) as List<Object?>;
    return list.cast<String>().toSet();
  } on Object {
    return const {};
  }
}

/// Turns a raw RGBA buffer into an image the framework can paint.
///
/// The pipeline works on plain bytes so it can cross an isolate boundary for
/// free; this is the one place that has to become a `ui.Image`.
Future<ui.Image> decodeRgba(RgbaImage image) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    image.bytes,
    image.width,
    image.height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}
