import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// A pixel-exact viewer for the rendered map.
///
/// Written by hand rather than with `InteractiveViewer` because that widget
/// pans and zooms but cannot rotate, and rotating the reference to match how you
/// are standing in game is the whole point. The gesture maths is a single 2D
/// similarity transform, `screen = translate + rotate * scale * image`, applied
/// so that whatever is under the fingers stays under the fingers.
class MapViewer extends StatefulWidget {
  const MapViewer({
    super.key,
    required this.image,
    this.mapPixel = 1,
    this.gridEvery = 16,
    this.showGrid = false,
    this.emptyLabel,
  });

  /// The image to show. Pass `null` to show [emptyLabel] instead.
  final ui.Image? image;

  /// How many image pixels make one map cell.
  ///
  /// The textured preview draws each block as a face texture, so the bitmap is
  /// this many times the map on each side. The badge reports map cells — the
  /// same `640x640` the size panel shows — and a zoom of one map cell per
  /// device pixel, not the blown-up texture.
  final int mapPixel;

  /// Draw a line every this many image pixels, marking chunk boundaries.
  final int gridEvery;
  final bool showGrid;

  final String? emptyLabel;

  @override
  State<MapViewer> createState() => MapViewerState();
}

class MapViewerState extends State<MapViewer> {
  double _scale = 1;
  double _rotation = 0;
  Offset _translation = Offset.zero;

  late double _startScale;
  late double _startRotation;
  late Offset _startTranslation;
  late Offset _focalAtStart;

  Size _viewport = Size.zero;
  ui.Image? _lastImage;
  bool _needsFit = false;

  /// Whether the user has moved the picture since the last fit. Until they do,
  /// a viewport change refits, so a window resize keeps the whole map visible
  /// instead of cropping it.
  bool _userAdjusted = false;

  /// Zoom, as a multiple of one image pixel per device pixel.
  double get zoom => _scale / (MediaQuery.devicePixelRatioOf(context));

  /// Resets to a centred, fitted view with no rotation.
  void reset() {
    setState(() {
      _rotation = 0;
      _scale = _fitScale();
      _translation = _centreTranslation(_scale, 0);
      _userAdjusted = false;
      _needsFit = false;
    });
  }

  /// Rotates by a multiple of a quarter turn, keeping the view centred.
  void rotateByQuarterTurns(int quarters) {
    setState(() {
      _rotation += quarters * math.pi / 2;
      _translation = _centreTranslation(_scale, _rotation);
      _userAdjusted = true;
    });
  }

  void setRotation(double radians) {
    setState(() {
      _rotation = radians;
      _translation = _centreTranslation(_scale, _rotation);
      _userAdjusted = true;
    });
  }

  double get rotation => _rotation;

  double _fitScale() {
    final image = widget.image;
    if (image == null || _viewport.isEmpty) return 1;
    final byWidth = _viewport.width / image.width;
    final byHeight = _viewport.height / image.height;
    return math.min(byWidth, byHeight) * 0.94;
  }

  Offset _centreTranslation(double scale, double rotation) {
    final image = widget.image;
    if (image == null) return Offset.zero;
    final centre = _viewport.center(Offset.zero);
    final half = _rotateScale(
      scale,
      rotation,
      Offset(image.width / 2, image.height / 2),
    );
    return centre - half;
  }

  static Offset _rotateScale(double scale, double rotation, Offset p) {
    final c = math.cos(rotation);
    final s = math.sin(rotation);
    return Offset(scale * (c * p.dx - s * p.dy), scale * (s * p.dx + c * p.dy));
  }

  static Offset _unrotateScale(double scale, double rotation, Offset v) {
    final c = math.cos(rotation);
    final s = math.sin(rotation);
    return Offset(
      (c * v.dx + s * v.dy) / scale,
      (-s * v.dx + c * v.dy) / scale,
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _startScale = _scale;
    _startRotation = _rotation;
    _startTranslation = _translation;
    _focalAtStart = details.localFocalPoint;
    _userAdjusted = true;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final focal = details.localFocalPoint;
    final nextScale = (_startScale * details.scale).clamp(0.02, 128.0);
    final nextRotation = _startRotation + details.rotation;

    // The image point that was under the focal point when the gesture began.
    final anchor = _unrotateScale(
      _startScale,
      _startRotation,
      _focalAtStart - _startTranslation,
    );
    // Put it back under wherever the focal point is now.
    final nextTranslation =
        focal - _rotateScale(nextScale, nextRotation, anchor);

    setState(() {
      _scale = nextScale;
      _rotation = nextRotation;
      _translation = nextTranslation;
      _userAdjusted = true;
    });
  }

  void _zoomAt(Offset focal, double factor) {
    final nextScale = (_scale * factor).clamp(0.02, 128.0);
    final anchor = _unrotateScale(_scale, _rotation, focal - _translation);
    setState(() {
      _translation = focal - _rotateScale(nextScale, _rotation, anchor);
      _scale = nextScale;
      _userAdjusted = true;
    });
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // Exponential so a notch feels the same at every zoom level.
    _zoomAt(event.localPosition, math.exp(-event.scrollDelta.dy / 240));
  }

  /// Maps a point in image pixel coordinates to viewport coordinates, using the
  /// same transform the widget paints with.
  ///
  /// Exposed so tests can assert on the actual transform rather than on a
  /// reimplementation of it.
  Offset imageToScreen(Offset imagePoint) {
    final mapped = _rotateScale(_scale, _rotation, imagePoint);
    return _translation + mapped;
  }

  /// The inverse of [imageToScreen].
  Offset screenToImage(Offset screenPoint) =>
      _unrotateScale(_scale, _rotation, screenPoint - _translation);

  /// Image pixels per map cell, or 1 when [MapViewer.mapPixel] does not tile
  /// the bitmap. A bad factor must not truncate the size into a lie.
  int get _mapCell {
    final image = widget.image;
    final cell = widget.mapPixel;
    if (image == null || cell <= 1) return 1;
    if (image.width % cell != 0 || image.height % cell != 0) return 1;
    return cell;
  }

  /// The 2D similarity transform `screen = translate + rotate * scale * image`.
  ///
  /// Built entry by entry rather than through `Matrix4.translate`/`scale`,
  /// which are deprecated, and because writing it out makes the one transform
  /// the whole widget depends on readable.
  Matrix4 _matrix() {
    final cosScaled = math.cos(_rotation) * _scale;
    final sinScaled = math.sin(_rotation) * _scale;
    return Matrix4.identity()
      ..setEntry(0, 0, cosScaled)
      ..setEntry(0, 1, -sinScaled)
      ..setEntry(1, 0, sinScaled)
      ..setEntry(1, 1, cosScaled)
      ..setEntry(0, 3, _translation.dx)
      ..setEntry(1, 3, _translation.dy);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final image = widget.image;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size != _viewport) {
          _viewport = size;
          // Refit on resize only while the user has not taken over, so a window
          // resize keeps the whole map in view instead of cropping it.
          if (!_userAdjusted) _needsFit = true;
        }
        // A result can arrive well after the first layout, so the fit has to
        // key off the image as well as the viewport. Keying it off the viewport
        // alone leaves the picture at 1:1 in the corner.
        if (!identical(image, _lastImage)) {
          _lastImage = image;
          _userAdjusted = false;
          _needsFit = image != null;
        }
        if (_needsFit && image != null && !_viewport.isEmpty) {
          _needsFit = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) reset();
          });
        }

        return ClipRect(
          child: Listener(
            onPointerSignal: _onPointerSignal,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              onDoubleTap: reset,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (image == null)
                    _EmptyState(label: widget.emptyLabel ?? '还没有生成预览')
                  else
                    // `Positioned` with only a corner given, so the child keeps
                    // its natural size. A plain child of an expanding `Stack`
                    // is forced to fill, which stretches the picture and leaves
                    // the transform scaling an already-blown-up image.
                    Positioned(
                      left: 0,
                      top: 0,
                      child: Transform(
                        transform: _matrix(),
                        alignment: Alignment.topLeft,
                        child: _ImageLayer(
                          image: image,
                          gridEvery: widget.gridEvery,
                          showGrid: widget.showGrid,
                          lineColor: scheme.outlineVariant.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      ),
                    ),
                  if (image != null)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: _NorthMarker(rotation: _rotation),
                    ),
                  if (image != null)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: _ZoomBadge(
                        zoom: zoom * _mapCell,
                        pixelWidth: image.width ~/ _mapCell,
                        pixelHeight: image.height ~/ _mapCell,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ImageLayer extends StatelessWidget {
  const _ImageLayer({
    required this.image,
    required this.gridEvery,
    required this.showGrid,
    required this.lineColor,
  });

  final ui.Image image;
  final int gridEvery;
  final bool showGrid;
  final Color lineColor;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: image.width.toDouble(),
        height: image.height.toDouble(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // `FilterQuality.none` is not a detail: the whole point is to see
            // individual map pixels, and any smoothing would hide exactly the
            // dithering texture the preview exists to show.
            RawImage(
              image: image,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.none,
            ),
            if (showGrid)
              CustomPaint(
                painter: _GridPainter(
                  width: image.width,
                  height: image.height,
                  every: gridEvery,
                  color: lineColor,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  const _GridPainter({
    required this.width,
    required this.height,
    required this.every,
    required this.color,
  });

  final int width;
  final int height;
  final int every;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1 / size.width.clamp(1, double.infinity) * width / 128;
    for (var x = every; x < width; x += every) {
      canvas.drawLine(
        Offset(x.toDouble(), 0),
        Offset(x.toDouble(), height.toDouble()),
        paint,
      );
    }
    for (var y = every; y < height; y += every) {
      canvas.drawLine(
        Offset(0, y.toDouble()),
        Offset(width.toDouble(), y.toDouble()),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.width != width ||
      old.height != height ||
      old.every != every ||
      old.color != color;
}

/// Shows which way north is, given the current rotation.
///
/// A mapart's up edge is north, so the arrow has to turn with the picture rather
/// than stay pinned to the screen. Line the arrow up with the way you are facing
/// in game and the reference matches the build.
class _NorthMarker extends StatelessWidget {
  const _NorthMarker({required this.rotation});

  final double rotation;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.rotate(
              angle: rotation,
              child: Icon(Icons.arrow_upward, size: 16, color: scheme.primary),
            ),
            const SizedBox(width: 5),
            Text(
              'N',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZoomBadge extends StatelessWidget {
  const _ZoomBadge({
    required this.zoom,
    required this.pixelWidth,
    required this.pixelHeight,
  });

  final double zoom;
  final int pixelWidth;
  final int pixelHeight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          '${pixelWidth}x$pixelHeight  ${zoom.toStringAsFixed(zoom < 10 ? 2 : 0)}x',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_outlined, size: 48, color: scheme.outline),
          const SizedBox(height: 12),
          Text(label, style: TextStyle(color: scheme.outline)),
        ],
      ),
    );
  }
}
