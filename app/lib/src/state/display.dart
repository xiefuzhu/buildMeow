import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapart_core/mapart_core.dart';

import '../data/assets.dart';
import '../data/rerender.dart';

/// Display operations have separate injection points from generation: a hide
/// operation must redraw the same plan without solving it again.
final previewDecoderProvider = Provider<Future<ui.Image> Function(RgbaImage)>(
  (ref) => decodeRgba,
);
final previewRasterizerProvider =
    Provider<Future<RgbaImage> Function(PreviewRequest)>((ref) => runRerender);
