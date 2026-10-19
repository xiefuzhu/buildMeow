import 'dart:isolate';
import 'dart:typed_data';

import 'package:mapart_core/mapart_core.dart';
import 'package:meta/meta.dart';

import 'pipeline.dart';

/// A re-render of the preview with some blocks hidden.
///
/// Deliberately not a `PipelineRequest`: hiding a block does not change the
/// solve, so there is no quantization, no height solving and no colour matching
/// here — only the drawing, which for a 5x5 build is still tens of millions of
/// texels and so still belongs off the UI thread.
@immutable
class PreviewRequest {
  const PreviewRequest({
    required this.plan,
    required this.hiddenBlocks,
    this.textureAtlas,
    this.textureIndex = const {},
    this.textureCell = 16,
  });

  final MapPlan plan;

  /// Indices into `plan.blocks`.
  final Set<int> hiddenBlocks;

  final Uint8List? textureAtlas;
  final Map<String, int> textureIndex;
  final int textureCell;
}

/// Runs [rerenderPreview] off the UI thread.
Future<RgbaImage> runRerender(PreviewRequest request) =>
    Isolate.run(() => rerenderPreview(request));

/// Draws the preview, with the hidden blocks shown as a checkerboard.
///
/// Top-level so `Isolate.run` can send it. Nothing here reads the file system
/// or a Flutter binding, which is what makes it safe to run in a background
/// isolate on Android as well as on Windows.
RgbaImage rerenderPreview(PreviewRequest request) {
  final atlas = request.textureAtlas;
  return renderTexturedPlan(
    plan: request.plan,
    atlas: atlas == null ? null : decodeAtlasPng(atlas),
    textureIndex: request.textureIndex,
    cell: request.textureCell,
    previewCell: boundedPreviewCell(
      request.plan.width,
      request.plan.height,
      request.textureCell,
    ),
    hiddenBlocks: request.hiddenBlocks,
  );
}
