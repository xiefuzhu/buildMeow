import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapart_core/mapart_core.dart';
import 'package:meta/meta.dart';

import '../data/assets.dart';
import 'generation.dart';
import 'project_models.dart';
export 'generation.dart';
export 'project_models.dart';
import '../data/preferences.dart';

/// The two tables, loaded once from the package assets.
final colorTableProvider = FutureProvider<ColorTable>(
  (ref) => MapartAssets.loadColorTable(),
);

final versionTableProvider = FutureProvider<VersionTable>(
  (ref) => MapartAssets.loadVersionTable(),
);

/// How many blocks of vertical freedom the solver gets, and where the build
/// sits. Derived from the target version rather than hard-coded, because the
/// overworld's limits changed in 1.17 and the answer has to fit whichever
/// version the user picked.
@immutable
class HeightPlan {
  const HeightPlan({required this.driftBudget, required this.baseHeight});

  final int driftBudget;
  final int baseHeight;
}

final heightPlanProvider = Provider<HeightPlan?>((ref) {
  final versions = ref.watch(versionTableProvider).value;
  final settings = ref.watch(settingsProvider);
  if (versions == null) return null;
  final version = versions.byId(settings.versionId);
  if (version == null) return null;
  final plan = suggestHeightPlan(version);
  return HeightPlan(driftBudget: plan.driftBudget, baseHeight: plan.baseHeight);
});

final blockColorsProvider = FutureProvider<Map<String, int>>(
  (ref) => MapartAssets.loadBlockColors(),
);

/// Minecraft's own Chinese names for blocks, so the interface and the blueprint
/// sheets label a block the way the game does.
final blockNamesProvider = FutureProvider<BlockNames>(
  (ref) => MapartAssets.loadBlockNames(),
);

/// The packed face textures, loaded once and shared.
///
/// The pipeline needs them to draw the preview, and hiding a block re-renders
/// the preview from them without going near the solver, so both paths read the
/// same load rather than decoding the atlas twice.
final textureAtlasProvider =
    FutureProvider<({Uint8List png, Map<String, int> index, int cell})>(
      (ref) => MapartAssets.loadBlockTextures(),
    );

/// The palette the parameters panel lists, built from the same code the
/// pipeline uses so the tiles cannot disagree with the solve.
///
/// Each block keeps the colour of its own texture when that average is known.
/// The shared map colour is only the fallback for a block the extractor could
/// not colour.
final blockCapabilitiesProvider = FutureProvider<BlockCapabilities>(
  (ref) => MapartAssets.loadBlockCapabilities(),
);

final paletteProvider = Provider<Palette?>((ref) {
  final table = ref.watch(colorTableProvider).value;
  final versions = ref.watch(versionTableProvider).value;
  final colors = ref.watch(blockColorsProvider).value;
  final rules = ref.watch(blockCapabilitiesProvider).value;
  final (versionId, kind, flatMap) = ref.watch(
    settingsProvider.select((s) => (s.versionId, s.artKind, s.flatMap)),
  );
  if (table == null || versions == null || colors == null || rules == null) {
    return null;
  }
  final version = versions.byId(versionId);
  if (version == null) return null;
  return resolveProductionPalette(
    table: table,
    version: version,
    kind: kind,
    flatMap: flatMap,
    blockColors: colors,
    capabilities: rules,
  );
});

/// The picture the user picked, plus its original bytes.
final sourceImageProvider = NotifierProvider<SourceImageNotifier, SourceImage?>(
  SourceImageNotifier.new,
);

class SourceImageNotifier extends Notifier<SourceImage?> {
  int _importRevision = 0;
  int beginImport() => ++_importRevision;
  bool isCurrentImport(int revision) =>
      ref.mounted && revision == _importRevision;
  bool completeImport(int revision, SourceImage image) {
    if (!isCurrentImport(revision)) return false;
    set(image);
    return true;
  }

  @override
  SourceImage? build() => null;

  void set(SourceImage? image) {
    _importRevision++;
    state = image;
  }

  void clear() => set(null);
}

final settingsProvider = NotifierProvider<SettingsNotifier, ProjectSettings>(
  SettingsNotifier.new,
);
final settingsLoaderProvider = Provider<Future<ProjectSettings?> Function()>(
  (ref) => Preferences.loadSettings,
);

class SettingsNotifier extends Notifier<ProjectSettings> {
  int _editRevision = 0;
  @override
  ProjectSettings build() => const ProjectSettings();

  /// Loads what was stored last time.
  ///
  /// Deliberately not in `build`: the notifier has to exist synchronously for
  /// the first frame, and a stored value should not clear a result that was
  /// already computed — there is none at startup, but the rule keeps the two
  /// paths from disagreeing later.
  Future<void> restore() async {
    final revision = _editRevision;
    final stored = await ref.read(settingsLoaderProvider)();
    if (ref.mounted && revision == _editRevision && stored != null) {
      state = stored;
    }
  }

  void update(ProjectSettings Function(ProjectSettings) change) {
    _editRevision++;
    final previous = state;
    final next = change(previous);
    state = next;
    unawaited(Preferences.saveSettings(next));
  }

  void setMaps({int? x, int? y}) =>
      update((s) => s.copyWith(mapsX: x?.clamp(1, 16), mapsY: y?.clamp(1, 16)));

  void setCropMode(CropMode mode) => update((s) => s.copyWith(cropMode: mode));

  void setArtKind(ArtKind kind) => update((s) => s.copyWith(artKind: kind));
  void setFlatMap(bool flat) => update((s) => s.copyWith(flatMap: flat));

  void setDither(DitherMode mode) => update((s) => s.copyWith(dither: mode));

  void setDitherThreshold(double value) =>
      update((s) => s.copyWith(ditherThreshold: value));

  void setDitherStrength(double value) =>
      update((s) => s.copyWith(ditherStrength: value));

  /// `null` removes the cap.
  void setMaxBlocks(int? value) => update(
    (s) => value == null
        ? s.copyWith(clearMaxBlocks: true)
        : s.copyWith(maxBlocks: value),
  );

  void setMetric(ColorMetric metric) =>
      update((s) => s.copyWith(metric: metric));

  void setVersion(String id) => update((s) => s.copyWith(versionId: id));

  void setBlockEnabled(String key, bool enabled) => update((s) {
    final next = Set<String>.from(s.disabledBlockKeys);
    if (enabled) {
      next.remove(key);
    } else {
      next.add(key);
    }
    return s.copyWith(disabledBlockKeys: next);
  });

  /// Switches a whole set of blocks on or off at once, which is what the
  /// per-colour "all" control and the palette-wide buttons use.
  void setBlocksEnabled(bool enabled, Iterable<String> keys) => update(
    (s) => s.copyWith(
      disabledBlockKeys: enabled
          ? (Set<String>.from(s.disabledBlockKeys)..removeAll(keys))
          : (Set<String>.from(s.disabledBlockKeys)..addAll(keys)),
    ),
  );

  void setIncludeSupportBlocks(bool value) =>
      update((s) => s.copyWith(includeSupportBlocks: value));
}

/// Blocks the user has switched off in the picture, by `PlanBlock.key`.
///
/// Keyed by the block's stable identity rather than by its index in the plan,
/// so the set survives a re-solve that reorders the list or drops a block
/// entirely. Hidden is a *display* state: it never changes the solve, so the
/// material list still counts what the build needs.
final hiddenBlockKeysProvider =
    NotifierProvider<HiddenBlocksNotifier, Set<String>>(
      HiddenBlocksNotifier.new,
    );

class HiddenBlocksNotifier extends Notifier<Set<String>> {
  int _editRevision = 0;
  @override
  Set<String> build() => const <String>{};

  /// Loads what was stored last time. Called once, from the app shell.
  Future<void> restore() async {
    final revision = _editRevision;
    final stored = await Preferences.loadHiddenBlocks();
    if (ref.mounted && revision == _editRevision && stored.isNotEmpty) {
      state = stored;
    }
  }

  void set(String key, bool hidden) {
    final next = Set<String>.from(state);
    if (hidden) {
      next.add(key);
    } else {
      next.remove(key);
    }
    _editRevision++;
    state = next;
    unawaited(Preferences.saveHiddenBlocks(next));
  }

  void toggle(String key) => set(key, !state.contains(key));

  void showAll() {
    if (state.isEmpty) return;
    _editRevision++;
    state = const <String>{};
    unawaited(Preferences.saveHiddenBlocks(const <String>{}));
  }

  /// Hides every block of the current picture.
  void hideAll(Iterable<String> keys) {
    _editRevision++;
    state = keys.toSet();
    unawaited(Preferences.saveHiddenBlocks(state));
  }
}

/// "Show only this block", or `null` when everything is on.
///
/// A second way of hiding rather than a filter: with one block selected the
/// preview shows that block alone, which is what you want when you are looking
/// for the pixels you have not built yet.
final soloBlockKeyProvider = NotifierProvider<SoloBlockNotifier, String?>(
  SoloBlockNotifier.new,
);

class SoloBlockNotifier extends Notifier<String?> {
  int _editRevision = 0;
  @override
  String? build() => null;

  Future<void> restore() async {
    final revision = _editRevision;
    final stored = await Preferences.loadSoloBlock();
    if (ref.mounted && revision == _editRevision && stored != null) {
      state = stored;
    }
  }

  void set(String? key) {
    _editRevision++;
    state = key;
    unawaited(Preferences.saveSoloBlock(key));
  }

  void toggle(String key) => set(state == key ? null : key);
}

/// The plan-block indices the preview should not draw, which is the hidden set
/// plus everything the solo selection excludes.
///
/// Derived in one place so the preview, the blueprint viewer and (later) the
/// floating window cannot disagree about what is hidden.
final hiddenPlanIndicesProvider = Provider<Set<int>>((ref) {
  final plan = ref.watch(resultProvider).value?.plan;
  if (plan == null) return const <int>{};
  final hidden = ref.watch(hiddenBlockKeysProvider);
  final solo = ref.watch(soloBlockKeyProvider);

  final out = <int>{};
  for (var i = 0; i < plan.blocks.length; i++) {
    final key = plan.blocks[i].key;
    if (solo != null) {
      if (key != solo) out.add(i);
    } else if (hidden.contains(key)) {
      out.add(i);
    }
  }
  return out;
});

/// Where exports go, remembered between runs.
///
/// On the desktop this is the folder the user picked, and it is remembered
/// rather than guessed at: Litematica's own default lives under
/// `%APPDATA%\.minecraft\schematics`, but every third-party launcher puts its
/// instance somewhere else, so writing there uninvited would be wrong.
///
/// Null means "ask", which is also what the mobile platforms do — there the
/// file goes through the system save dialog, one file at a time, and there is
/// no folder to remember.
final exportDirectoryProvider =
    NotifierProvider<ExportDirectoryNotifier, String?>(
      ExportDirectoryNotifier.new,
    );

class ExportDirectoryNotifier extends Notifier<String?> {
  int _editRevision = 0;
  @override
  String? build() => null;

  Future<void> restore() async {
    final revision = _editRevision;
    final stored = await Preferences.loadExportDirectory();
    if (ref.mounted && revision == _editRevision && stored != null) {
      state = stored;
    }
  }

  void set(String? path) {
    _editRevision++;
    state = path;
    unawaited(Preferences.saveExportDirectory(path));
  }
}
