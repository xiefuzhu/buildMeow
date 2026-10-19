import 'package:material_ui/material_ui.dart';

/// The seed used when the platform has no dynamic colour to offer.
///
/// A deep desaturated teal. Deliberately not the Material default purple — this
/// app is a tool that sits next to a game, and the preview has to be the thing
/// your eye lands on, not the chrome.
const Color kSeedColor = Color(0xFF2F6B5F);

/// Builds the two themes the app runs with.
///
/// Material 3 is the only style here; there is no Material 2 fallback to keep in
/// sync. `dynamic_color` supplies a full `ColorScheme` on Android 12+ (wallpaper)
/// and on Windows (system accent), and [ColorScheme.fromSeed] covers everything
/// else.
abstract final class AppTheme {
  static ColorScheme contrastScheme(Brightness brightness) =>
      ColorScheme.fromSeed(
        seedColor: kSeedColor,
        brightness: brightness,
        contrastLevel: 1,
      );
  static ThemeData light(ColorScheme scheme) => _build(scheme);

  static ThemeData dark(ColorScheme scheme) => _build(scheme);

  static ThemeData _build(ColorScheme scheme) {
    final base = ThemeData(
      colorScheme: scheme,
      fontFamily: 'NotoSansSC',
      fontFamilyFallback: const ['Microsoft YaHei', 'Segoe UI'],
    );
    return base.copyWith(
      // A map preview is a picture, not a document: let it use the full width
      // on a phone rather than inheriting the desktop reading measure.
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
        scrolledUnderElevation: 3,
      ),
      cardTheme: CardThemeData(
        clipBehavior: Clip.antiAlias,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      sliderTheme: const SliderThemeData(
        showValueIndicator: ShowValueIndicator.onDrag,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
