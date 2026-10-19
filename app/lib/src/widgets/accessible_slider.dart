import 'package:material_ui/material_ui.dart';

/// Keep the slider's value-indicator portal inside its own overlay. Flutter
/// 3.47 can otherwise serialize an orphan node when a scroll/page hides it,
/// breaking the Windows accessibility bridge (flutter/flutter#190357).
/// This retains the Material slider, keyboard control and full semantics.
class AccessibleSlider extends StatelessWidget {
  const AccessibleSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.semanticFormatterCallback,
  });
  final double value;
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final SemanticFormatterCallback? semanticFormatterCallback;

  @override
  Widget build(BuildContext context) => Overlay.wrap(
    alwaysSizeToContent: true,
    clipBehavior: Clip.none,
    child: Slider(
      value: value,
      onChanged: onChanged,
      min: min,
      max: max,
      divisions: divisions,
      label: label,
      semanticFormatterCallback: semanticFormatterCallback,
    ),
  );
}
