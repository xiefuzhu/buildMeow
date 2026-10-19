import 'dart:typed_data';

import 'package:mapart_core/mapart_core.dart';
import 'package:meta/meta.dart';

export 'package:mapart_core/mapart_core.dart' show ArtKind;

@immutable
class SourceImage {
  const SourceImage({
    required this.name,
    required this.bytes,
    required this.width,
    required this.height,
  });

  final String name;
  final Uint8List bytes;
  final int width;
  final int height;
}

/// Everything the user can tune.
@immutable
class ProjectSettings {
  const ProjectSettings({
    this.mapsX = 1,
    this.mapsY = 1,
    this.cropMode = CropMode.contain,
    this.artKind = ArtKind.blockPixels,
    this.flatMap = false,
    this.dither = DitherMode.floydSteinberg,
    this.ditherThreshold = 8.0,
    this.ditherStrength = 1.0,
    this.maxBlocks = 60,
    this.metric = ColorMetric.chromaWeighted,
    this.versionId = '26.1.2',
    this.disabledBlockKeys = const <String>{},
    this.includeSupportBlocks = false,
    this.background = const Rgb(255, 255, 255),
  });

  /// How many maps across and down. One map is 128x128 map pixels.
  final int mapsX;
  final int mapsY;

  final CropMode cropMode;

  /// Block pixel art or a map item. They do not look at the same colours.
  final ArtKind artKind;
  final bool flatMap;

  final DitherMode dither;
  final double ditherThreshold;

  /// How much of each pixel's dither error is carried to its neighbours,
  /// `0..1`. Full strength is textbook Floyd-Steinberg; backing it off trades
  /// average accuracy for less speckle, which matters because every dithered
  /// pixel is another block to place.
  final double ditherStrength;

  /// Keep at most this many blocks, the ones serving the most pixels.
  ///
  /// Defaults to 60. Measured on the four test pictures, capping to 60 raised
  /// the 5×5 blurred error by at most 0.11 while taking the block count from
  /// 110–192 down to 60. 40 costs at most 0.22; 20 starts to show. A picture
  /// does not need 300 kinds of block to look right, and the shopping list is
  /// the thing that decides how long the build takes.
  final int? maxBlocks;

  /// How "close" two colours are judged to be when matching. The default,
  /// [ColorMetric.chromaWeighted], keeps pale but colourful regions on their
  /// own hue instead of letting them drift to a grey of the right lightness.
  final ColorMetric metric;
  final String versionId;

  /// Blocks switched off, by `PaletteEntry.key`.
  ///
  /// Per block rather than per colour, because the point of the expanded
  /// palette is that a colour can be built out of any of its blocks: turning
  /// one off hands the colour to the next one still on. A colour disappears
  /// only once every one of its supported blocks is off. Unsupported candidates
  /// are filtered independently by the production palette.
  final Set<String> disabledBlockKeys;

  /// Whether blocks that need something underneath them are offered too.
  ///
  /// Retained for compatibility; production palettes currently exclude water,
  /// gravity and support-dependent blocks because their construction is unsolved.
  final bool includeSupportBlocks;

  /// What transparent areas are flattened onto.
  final Rgb background;

  int get mapCount => mapsX * mapsY;
  int get pixelWidth => mapsX * 128;
  int get pixelHeight => mapsY * 128;

  ProjectSettings copyWith({
    int? mapsX,
    int? mapsY,
    CropMode? cropMode,
    ArtKind? artKind,
    bool? flatMap,
    DitherMode? dither,
    double? ditherThreshold,
    double? ditherStrength,
    int? maxBlocks,
    bool clearMaxBlocks = false,
    ColorMetric? metric,
    String? versionId,
    Set<String>? disabledBlockKeys,
    bool? includeSupportBlocks,
    Rgb? background,
  }) => ProjectSettings(
    mapsX: mapsX ?? this.mapsX,
    mapsY: mapsY ?? this.mapsY,
    cropMode: cropMode ?? this.cropMode,
    artKind: artKind ?? this.artKind,
    flatMap: flatMap ?? this.flatMap,
    dither: dither ?? this.dither,
    ditherThreshold: ditherThreshold ?? this.ditherThreshold,
    ditherStrength: ditherStrength ?? this.ditherStrength,
    maxBlocks: clearMaxBlocks ? null : (maxBlocks ?? this.maxBlocks),
    metric: metric ?? this.metric,
    versionId: versionId ?? this.versionId,
    disabledBlockKeys: disabledBlockKeys ?? this.disabledBlockKeys,
    includeSupportBlocks: includeSupportBlocks ?? this.includeSupportBlocks,
    background: background ?? this.background,
  );

  /// Whether the settings that change the rendered image differ from [other].
  ///
  /// Used to decide whether an existing result is still valid: flipping the
  /// theme or opening a panel should not throw away a solve.
  bool affectsRender(ProjectSettings other) =>
      mapsX != other.mapsX ||
      mapsY != other.mapsY ||
      cropMode != other.cropMode ||
      artKind != other.artKind ||
      flatMap != other.flatMap ||
      dither != other.dither ||
      ditherThreshold != other.ditherThreshold ||
      ditherStrength != other.ditherStrength ||
      maxBlocks != other.maxBlocks ||
      metric != other.metric ||
      versionId != other.versionId ||
      background != other.background ||
      includeSupportBlocks != other.includeSupportBlocks ||
      !_sameSet(disabledBlockKeys, other.disabledBlockKeys);

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.every(b.contains);

  /// The settings as plain JSON for the preference store.
  Map<String, dynamic> toJson() => {
    'mapsX': mapsX,
    'mapsY': mapsY,
    'cropMode': cropMode.name,
    'artKind': artKind.name,
    'flatMap': flatMap,
    'dither': dither.name,
    'ditherThreshold': ditherThreshold,
    'ditherStrength': ditherStrength,
    'maxBlocks': maxBlocks,
    'metric': metric.name,
    'versionId': versionId,
    'disabledBlockKeys': disabledBlockKeys.toList()..sort(),
    'includeSupportBlocks': includeSupportBlocks,
    'background': [background.r, background.g, background.b],
  };

  /// Reads back what [toJson] wrote.
  ///
  /// Every field is optional and falls back to its default, so a file written
  /// by an older build still opens. A value that is the wrong *type* is treated
  /// the same way rather than throwing: the alternative is an app that will not
  /// start because a preferences file was edited.
  factory ProjectSettings.fromJson(Map<String, dynamic> json) {
    T? named<T extends Enum>(List<T> values, String key) {
      final name = json[key];
      if (name is! String) return null;
      for (final value in values) {
        if (value.name == name) return value;
      }
      return null;
    }

    final background = json['background'];
    return ProjectSettings(
      mapsX: (_int(json['mapsX']) ?? 1).clamp(1, 16),
      mapsY: (_int(json['mapsY']) ?? 1).clamp(1, 16),
      cropMode: named(CropMode.values, 'cropMode') ?? CropMode.contain,
      artKind: named(ArtKind.values, 'artKind') ?? ArtKind.blockPixels,
      flatMap: json['flatMap'] == true,
      dither: named(DitherMode.values, 'dither') ?? DitherMode.floydSteinberg,
      ditherThreshold: (_double(json['ditherThreshold']) ?? 8.0).clamp(0, 24),
      ditherStrength: (_double(json['ditherStrength']) ?? 1.0).clamp(0, 1),
      maxBlocks: json.containsKey('maxBlocks') && json['maxBlocks'] == null
          ? null
          : (_int(json['maxBlocks']) ?? 60).clamp(1, 1000),
      metric: named(ColorMetric.values, 'metric') ?? ColorMetric.chromaWeighted,
      versionId: VersionTable.defaultVersionId,
      disabledBlockKeys: json['disabledBlockKeys'] is List
          ? (json['disabledBlockKeys'] as List<dynamic>)
                .whereType<String>()
                .toSet()
          : const <String>{},
      includeSupportBlocks: json['includeSupportBlocks'] is bool
          ? json['includeSupportBlocks'] as bool
          : false,
      background: background is List && background.length == 3
          ? Rgb(
              (_int(background[0]) ?? 255).clamp(0, 255),
              (_int(background[1]) ?? 255).clamp(0, 255),
              (_int(background[2]) ?? 255).clamp(0, 255),
            )
          : const Rgb(255, 255, 255),
    );
  }

  static int? _int(Object? value) =>
      value is num && value.isFinite ? value.toInt() : null;
  static double? _double(Object? value) =>
      value is num && value.isFinite ? value.toDouble() : null;
}
