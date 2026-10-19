import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'package:mapart_core/mapart_core.dart';
import 'package:material_ui/material_ui.dart';

/// A cell of the picture, in map pixels.
typedef BlueprintCell = ({int x, int y});

/// The picture drawn as a grid of blocks, with chunk lines and a tap readout.
///
/// Painted from the plan rather than from a bitmap: the same `MapPlan` the
/// exporters read, so what is on screen is the build and not a picture of it.
/// That also makes hiding a block a per-cell decision, and keeps every zoom
/// level crisp without any image resampling.
///
/// `InteractiveViewer` for the pan and zoom, which is what the plan called for;
/// the readout is a `GestureDetector` *inside* it, so a tap arrives in the
/// child's own coordinates and no transform has to be inverted by hand.
class BlueprintViewer extends StatefulWidget {
  const BlueprintViewer({
    super.key,
    required this.plan,
    required this.hidden,
    this.tile,
    this.onPick,
  });

  final MapPlan plan;

  /// Indices into `plan.blocks` that are hidden and drawn as a checkerboard.
  final Set<int> hidden;

  /// The map tile to show, or null for the whole picture.
  final ({int x, int y})? tile;

  final ValueChanged<BlueprintCell?>? onPick;

  @override
  State<BlueprintViewer> createState() => BlueprintViewerState();
}

class BlueprintViewerState extends State<BlueprintViewer> {
  final _focus = FocusNode(debugLabel: '图纸键盘导航');
  final _transform = TransformationController();
  BlueprintCell? _picked;
  Size? _viewport;

  @override
  void dispose() {
    _focus.dispose();
    _transform.dispose();
    super.dispose();
  }

  /// Back to 1:1 with the tile centred, which is what "复位" has to mean here
  /// because the cell size already fits the tile to the viewport.
  void reset() {
    setState(() {
      _transform.value = Matrix4.identity();
      _picked = null;
      widget.onPick?.call(null);
    });
  }

  @override
  void didUpdateWidget(BlueprintViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different tile or a different picture is a different thing to look at,
    // so the pan and zoom from the last one do not carry over.
    if (oldWidget.tile != widget.tile ||
        !identical(oldWidget.plan, widget.plan)) {
      _transform.value = Matrix4.identity();
      _picked = null;
      // The parent's selection is cleared after the frame rather than here:
      // this runs during the build phase, and `onPick` calls `setState` on the
      // page, which is an ancestor of the widget being built — doing it inline
      // throws "setState() or markNeedsBuild() called during build".
      final onPick = widget.onPick;
      if (onPick != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) onPick(null);
        });
      }
    }
  }

  ({int x0, int y0, int x1, int y1}) get _bounds {
    final tile = widget.tile;
    if (tile == null) {
      return (x0: 0, y0: 0, x1: widget.plan.width, y1: widget.plan.height);
    }
    return widget.plan.tileBounds(tile.x, tile.y);
  }

  @override
  Widget build(BuildContext context) {
    final bounds = _bounds;
    final columns = bounds.x1 - bounds.x0;
    final rows = bounds.y1 - bounds.y0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        if (_viewport != viewport) {
          _viewport = viewport;
          _transform.value = Matrix4.identity();
        }
        // Fit every cell, including large overviews. A minimum cell size would
        // make the painter's extent exceed its layout box and clip the work.
        final cell = math.min(
          12.0,
          math.min(
            constraints.maxWidth * 0.94 / columns,
            constraints.maxHeight * 0.94 / rows,
          ),
        );
        final size = Size(columns * cell, rows * cell);

        return Focus(
          focusNode: _focus,
          onFocusChange: (_) => setState(() {}),
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
              return KeyEventResult.ignored;
            }
            final delta = switch (event.logicalKey) {
              LogicalKeyboardKey.arrowLeft => (x: -1, y: 0),
              LogicalKeyboardKey.arrowRight => (x: 1, y: 0),
              LogicalKeyboardKey.arrowUp => (x: 0, y: -1),
              LogicalKeyboardKey.arrowDown => (x: 0, y: 1),
              LogicalKeyboardKey.enter ||
              LogicalKeyboardKey.home => (x: 0, y: 0),
              _ => null,
            };
            if (delta == null) return KeyEventResult.ignored;
            final at = event.logicalKey == LogicalKeyboardKey.home
                ? null
                : _picked;
            final next = (
              x: ((at?.x ?? bounds.x0) + (at == null ? 0 : delta.x)).clamp(
                bounds.x0,
                bounds.x1 - 1,
              ),
              y: ((at?.y ?? bounds.y0) + (at == null ? 0 : delta.y)).clamp(
                bounds.y0,
                bounds.y1 - 1,
              ),
            );
            setState(() => _picked = next);
            widget.onPick?.call(next);
            return KeyEventResult.handled;
          },
          child: Semantics(
            label: '图纸画布，按 Tab 聚焦后用方向键选择格子，Home 返回左上角',
            focused: _focus.hasFocus,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: _focus.hasFocus
                      ? Theme.of(context).colorScheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: ClipRect(
                child: InteractiveViewer(
                  transformationController: _transform,
                  minScale: 0.4,
                  maxScale: 24,
                  boundaryMargin: const EdgeInsets.all(64),
                  child: Center(
                    child: GestureDetector(
                      onTapUp: (details) =>
                          _pick(details.localPosition, cell, bounds),
                      child: SizedBox(
                        width: size.width,
                        height: size.height,
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: BlueprintPainter(
                              plan: widget.plan,
                              hidden: widget.hidden,
                              bounds: bounds,
                              cell: cell,
                              picked: _picked,
                              gridColor: Theme.of(context)
                                  .colorScheme
                                  .outlineVariant
                                  .withValues(alpha: 0.55),
                              pickedColor: Theme.of(context)
                                  .colorScheme
                                  .primary,
                              surface: Theme.of(context).colorScheme.surface,
                              onSurface: Theme.of(context)
                                  .colorScheme
                                  .onSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _pick(
    Offset at,
    double cell,
    ({int x0, int y0, int x1, int y1}) bounds,
  ) {
    if (cell <= 0) return;
    _focus.requestFocus();
    final x = bounds.x0 + (at.dx / cell).floor();
    final y = bounds.y0 + (at.dy / cell).floor();
    if (x < bounds.x0 || x >= bounds.x1 || y < bounds.y0 || y >= bounds.y1) {
      return;
    }
    setState(() => _picked = (x: x, y: y));
    widget.onPick?.call(_picked);
  }
}

/// Paints the block grid, the 16x16 chunk lines and the reference row.
class BlueprintPainter extends CustomPainter {
  const BlueprintPainter({
    required this.plan,
    required this.hidden,
    required this.bounds,
    required this.cell,
    required this.picked,
    required this.gridColor,
    required this.pickedColor,
    required this.surface,
    required this.onSurface,
  });

  final MapPlan plan;
  final Set<int> hidden;
  final ({int x0, int y0, int x1, int y1}) bounds;
  final double cell;
  final BlueprintCell? picked;
  final Color gridColor;
  final Color pickedColor;
  final Color surface;
  final Color onSurface;

  /// How many map pixels one chunk is. A chunk is 16 blocks, so the lines fall
  /// where the game's own chunk borders do.
  static const int chunk = 16;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    final pixels = math.max(1, cell.round());

    for (var y = bounds.y0; y < bounds.y1; y++) {
      for (var x = bounds.x0; x < bounds.x1; x++) {
        final left = (x - bounds.x0) * cell;
        final top = (y - bounds.y0) * cell;
        final index = plan.blockIndexAt(x, y);
        if (hidden.contains(index)) {
          // The same checkerboard the exports and the preview use, so a hidden
          // block looks hidden wherever it is looked at.
          paint.color = _checker(pixels);
          canvas.drawRect(Rect.fromLTWH(left, top, cell, cell), paint);
          _paintChecker(canvas, left, top, cell, pixels);
          continue;
        }
        paint.color = _color(plan.colorAt(x, y));
        canvas.drawRect(Rect.fromLTWH(left, top, cell, cell), paint);
      }
    }

    _paintReferenceRow(canvas, size);
    _paintChunkLines(canvas, size);
    _paintPicked(canvas);
  }

  Color _checker(int pixels) =>
      _color(pixels >= 4 ? HiddenCell.light : HiddenCell.flat);

  /// Draws the checkerboard over a cell, in device-independent pixels, using
  /// core's own pattern so the squares line up with the exported images.
  void _paintChecker(
    Canvas canvas,
    double left,
    double top,
    double cell,
    int pixels,
  ) {
    final paint = Paint()..style = PaintingStyle.fill;
    final square = math.max(2, pixels ~/ 2).toDouble();
    for (var dy = 0.0; dy < cell; dy += square) {
      for (var dx = 0.0; dx < cell; dx += square) {
        final light = ((dx ~/ square).floor() + (dy ~/ square).floor()).isEven;
        paint.color = _color(light ? HiddenCell.light : HiddenCell.dark);
        canvas.drawRect(
          Rect.fromLTWH(left + dx, top + dy, square, square),
          paint,
        );
      }
    }
  }

  /// The extra row north of the picture, which is built but is not part of any
  /// map. Drawn as a hatched band so it is never mistaken for a row of the
  /// design.
  void _paintReferenceRow(Canvas canvas, Size size) {
    if (bounds.y0 != 0 || !plan.requiresReferenceRow) return;
    final paint = Paint()
      ..color = _color(
        plan.blocks.isEmpty
            ? HiddenCell.flat
            : plan.blockAt(0, 0).tone(ShadeTier.normal),
      )
      ..style = PaintingStyle.fill;
    // A sliver, because the row itself is above the top edge: all that can be
    // drawn inside the child is a marker for where it starts.
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, 3), paint);

    final stripe = Paint()
      ..color = onSurface.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    for (var x = -6.0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, 3), Offset(x + 6, 0), stripe);
    }
  }

  void _paintChunkLines(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = gridColor
      ..strokeWidth = math.min(1, cell / 4);
    // Lines land on chunk borders in the picture's own coordinates, so they do
    // not move when the view is a single tile rather than the whole picture.
    for (var x = bounds.x0; x < bounds.x1; x++) {
      if (x % chunk != 0) continue;
      final left = (x - bounds.x0) * cell;
      canvas.drawLine(Offset(left, 0), Offset(left, size.height), paint);
    }
    for (var y = bounds.y0; y < bounds.y1; y++) {
      if (y % chunk != 0) continue;
      final top = (y - bounds.y0) * cell;
      canvas.drawLine(Offset(0, top), Offset(size.width, top), paint);
    }
  }

  void _paintPicked(Canvas canvas) {
    final cell_ = picked;
    if (cell_ == null) return;
    if (cell_.x < bounds.x0 ||
        cell_.x >= bounds.x1 ||
        cell_.y < bounds.y0 ||
        cell_.y >= bounds.y1) {
      return;
    }
    final left = (cell_.x - bounds.x0) * cell;
    final top = (cell_.y - bounds.y0) * cell;
    final paint = Paint()
      ..color = pickedColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(Rect.fromLTWH(left, top, cell, cell), paint);
  }

  static Color _color(Rgb rgb) => Color.fromARGB(255, rgb.r, rgb.g, rgb.b);

  @override
  bool shouldRepaint(BlueprintPainter old) =>
      !identical(old.plan, plan) ||
      old.hidden != hidden ||
      old.bounds != bounds ||
      old.cell != cell ||
      old.picked != picked ||
      old.gridColor != gridColor ||
      old.pickedColor != pickedColor;
}
