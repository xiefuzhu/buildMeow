import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/preferences.dart';

class AccessibilityOptions {
  const AccessibilityOptions({this.highContrast = false, this.textScale = 1});
  final bool highContrast;
  final double textScale;
}

final accessibilityProvider =
    NotifierProvider<AccessibilityNotifier, AccessibilityOptions>(
      AccessibilityNotifier.new,
    );

class AccessibilityNotifier extends Notifier<AccessibilityOptions> {
  int _revision = 0;
  @override
  AccessibilityOptions build() => const AccessibilityOptions();

  Future<void> restore() async {
    final revision = _revision;
    final raw = await Preferences.loadAccessibility();
    try {
      final json = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
      final scale = json['scale'];
      if (ref.mounted && revision == _revision) {
        state = AccessibilityOptions(
          highContrast: json['contrast'] == true,
          textScale: scale is num && scale.isFinite
              ? scale.toDouble().clamp(1, 2)
              : 1,
        );
      }
    } on Object {
      // Damaged optional appearance settings fall back to system defaults.
    }
  }

  void set({bool? highContrast, double? textScale}) {
    _revision++;
    state = AccessibilityOptions(
      highContrast: highContrast ?? state.highContrast,
      textScale: textScale != null && textScale.isFinite
          ? textScale.clamp(1, 2)
          : state.textScale,
    );
    unawaited(
      Preferences.saveAccessibility(
        jsonEncode({'contrast': state.highContrast, 'scale': state.textScale}),
      ),
    );
  }
}

/// Multiply the platform's scaler without discarding its nonlinear curve.
class AppTextScaler extends TextScaler {
  const AppTextScaler(this.system, this.multiplier);
  final TextScaler system;
  final double multiplier;
  @override
  double scale(double fontSize) => system.scale(fontSize) * multiplier;
  @override
  double get textScaleFactor => scale(14) / 14;
}
