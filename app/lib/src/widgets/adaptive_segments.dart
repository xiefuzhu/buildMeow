import 'package:material_ui/material_ui.dart';

/// Let choices grow vertically when their labels no longer fit in one row.
class AdaptiveSegments<T> extends StatelessWidget {
  const AdaptiveSegments({
    super.key,
    required this.segments,
    required this.selected,
    this.onSelectionChanged,
    this.style,
    this.showSelectedIcon = true,
  });
  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>>? onSelectionChanged;
  final ButtonStyle? style;
  final bool showSelectedIcon;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      return SegmentedButton<T>(
        direction: constraints.maxWidth < segments.length * 115 * scale
            ? Axis.vertical
            : Axis.horizontal,
        segments: segments,
        selected: selected,
        onSelectionChanged: onSelectionChanged,
        style: style,
        showSelectedIcon: showSelectedIcon,
      );
    },
  );
}
