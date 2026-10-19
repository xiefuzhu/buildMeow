import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:mapart_core/mapart_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:meta/meta.dart';
import 'package:path_provider/path_provider.dart';

import 'blueprint_layout.dart';
import 'blueprint_pdf.dart';
import 'blueprint_png.dart';
import 'material_csv.dart';

/// The kinds of file an export can produce.
enum ExportFormat {
  litematic('Litematica 投影', '.litematic'),
  schem('WorldEdit 原理图', '.schem'),
  pdf('图纸 PDF', '.pdf'),
  png('图纸 PNG', '.png'),
  csv('材料清单 CSV', '.csv');

  const ExportFormat(this.label, this.extension);

  final String label;
  final String extension;
}

@immutable
class ExportOptions {
  const ExportOptions({
    this.formats = const {
      ExportFormat.litematic,
      ExportFormat.schem,
      ExportFormat.pdf,
      ExportFormat.png,
      ExportFormat.csv,
    },
    this.shape = ExportShape.surface,
    this.includeReferenceRow = true,
    this.baseName = 'mapart',
    this.pngCell = 8,
    this.pngPerTile = true,
    this.pngOverview = true,
    this.referenceRows = const {},
  });

  final Set<ExportFormat> formats;

  /// Surface or solid — see [ExportShape].
  final ExportShape shape;

  /// Whether the schematic carries the extra reference row north of the
  /// picture.
  ///
  /// On by default, because it is part of the build and leaving it out is the
  /// easiest way to end up with a map whose top row is the wrong shade. Turning
  /// it off makes the schematic exactly the map area, which is easier to line up
  /// if you would rather build that row yourself.
  final bool includeReferenceRow;

  final String baseName;

  /// Pixels per block in the PNG sheets.
  final int pngCell;

  final bool pngPerTile;
  final bool pngOverview;
  final Map<ArtKind, bool> referenceRows;

  ExportOptions copyWith({
    Set<ExportFormat>? formats,
    ExportShape? shape,
    bool? includeReferenceRow,
    String? baseName,
    int? pngCell,
    bool? pngPerTile,
    bool? pngOverview,
    Map<ArtKind, bool>? referenceRows,
  }) => ExportOptions(
    formats: formats ?? this.formats,
    shape: shape ?? this.shape,
    includeReferenceRow: includeReferenceRow ?? this.includeReferenceRow,
    baseName: baseName ?? this.baseName,
    pngCell: pngCell ?? this.pngCell,
    pngPerTile: pngPerTile ?? this.pngPerTile,
    pngOverview: pngOverview ?? this.pngOverview,
    referenceRows: referenceRows ?? this.referenceRows,
  );

  Map<String, dynamic> toJson() => {
    'formats': formats.map((f) => f.name).toList(),
    'shape': shape.name,
    'includeReferenceRow': includeReferenceRow,
    'baseName': baseName,
    'pngCell': pngCell,
    'pngPerTile': pngPerTile,
    'pngOverview': pngOverview,
    'referenceRows': {
      for (final e in referenceRows.entries) e.key.name: e.value,
    },
  };

  factory ExportOptions.fromJson(Map<String, dynamic> json) {
    const defaults = ExportOptions();
    final rawFormats = json['formats'];
    final rawRows = json['referenceRows'];
    final rawCell = json['pngCell'];
    return ExportOptions(
      formats: rawFormats is List
          ? ExportFormat.values
                .where((f) => rawFormats.contains(f.name))
                .toSet()
          : defaults.formats,
      shape:
          ExportShape.values
              .where((s) => s.name == json['shape'])
              .firstOrNull ??
          defaults.shape,
      includeReferenceRow: json['includeReferenceRow'] is bool
          ? json['includeReferenceRow'] as bool
          : defaults.includeReferenceRow,
      baseName: json['baseName'] is String
          ? json['baseName'] as String
          : defaults.baseName,
      pngCell: rawCell is num && rawCell.isFinite
          ? rawCell.toInt().clamp(1, 32)
          : defaults.pngCell,
      pngPerTile: json['pngPerTile'] is bool
          ? json['pngPerTile'] as bool
          : defaults.pngPerTile,
      pngOverview: json['pngOverview'] is bool
          ? json['pngOverview'] as bool
          : defaults.pngOverview,
      referenceRows: {
        if (rawRows is Map)
          for (final kind in ArtKind.values)
            if (rawRows[kind.name] is bool) kind: rawRows[kind.name] as bool,
      },
    );
  }
}

/// One file the export produced, in memory until it is written somewhere.
@immutable
class ExportedFile {
  const ExportedFile({
    required this.name,
    required this.bytes,
    this.path,
    this.error,
  });

  final String name;
  final Uint8List bytes;

  /// Where it was written, once it has been. Null while it is still in memory.
  final String? path;
  final String? error;
  String get status => path != null
      ? "已保存"
      : error != null
      ? "失败"
      : "已取消";
  ExportedFile failed(Object reason) =>
      ExportedFile(name: name, bytes: bytes, error: "$reason");

  int get size => bytes.length;

  ExportedFile savedTo(String where) =>
      ExportedFile(name: name, bytes: bytes, path: where);
}

/// A completed save attempt, without retaining the generated file bytes.
@immutable
class ExportFileResult {
  const ExportFileResult({
    required this.name,
    required this.size,
    this.path,
    this.error,
  });

  final String name;
  final int size;
  final String? path;
  final String? error;
  String get status => path != null
      ? '已保存'
      : error != null
      ? '失败'
      : '已取消';
}

/// What an export produced.
@immutable
class ExportResult {
  const ExportResult({
    required this.files,
    required this.elapsed,
    required this.warnings,
  });

  final List<ExportFileResult> files;
  final Duration elapsed;
  final List<String> warnings;

  int get totalBytes => files.fold(0, (sum, file) => sum + file.size);
}

/// Everything the schematic and CSV writers need. Plain data, so it can cross
/// into an isolate.
@immutable
class DataExportRequest {
  const DataExportRequest({
    required this.plan,
    required this.options,
    this.author = '建喵!',
    this.sourceName,
    this.memoryBudget = BuildSummary.defaultMemoryBudget,
  });

  final MapPlan plan;
  final ExportOptions options;
  final String author;
  final String? sourceName;
  final int memoryBudget;
}

/// Builds the schematics and the shopping list.
///
/// Top-level so `Isolate.run` can send it: a 5x5 solid build is tens of seconds
/// of bit packing, and blocking the frame loop for that would freeze the window
/// with no way to show progress.
List<ExportedFile> buildDataFiles(DataExportRequest request) {
  final plan = request.plan;
  final options = request.options;
  final summary = BuildSummary.fromPlan(
    plan,
    shape: options.shape,
    includeReferenceRow: options.includeReferenceRow,
  );
  final base = _safeName(options.baseName);
  final out = <ExportedFile>[];

  if (options.formats.contains(ExportFormat.litematic) ||
      options.formats.contains(ExportFormat.schem)) {
    if (!plan.fitsWorld) {
      throw StateError('作品高度超出目标版本范围，请减少纵向张数或调整配色后重新生成。');
    }
    summary.checkMemory(budget: request.memoryBudget);
    final structure = buildStructure(
      plan,
      shape: options.shape,
      includeReferenceRow: options.includeReferenceRow,
    );
    if (options.formats.contains(ExportFormat.litematic)) {
      out.add(
        ExportedFile(
          name: '${base}_${plan.mapsX}x${plan.mapsY}.litematic',
          bytes: writeLitematic(
            structure,
            dataVersion: plan.dataVersion,
            metadata: LitematicMetadata(
              name: request.sourceName ?? base,
              author: request.author,
              description:
                  '${plan.width}x${plan.height}, '
                  '${options.shape.name}, Y ${plan.minHeight}..${plan.maxHeight}',
            ),
          ),
        ),
      );
    }
    if (options.formats.contains(ExportFormat.schem)) {
      out.add(
        ExportedFile(
          name: '${base}_${plan.mapsX}x${plan.mapsY}.schem',
          bytes: writeSpongeSchematic(
            structure,
            dataVersion: plan.dataVersion,
            name: request.sourceName ?? base,
            author: request.author,
          ),
        ),
      );
    }
  }

  if (options.formats.contains(ExportFormat.csv)) {
    out.add(
      ExportedFile(
        name: '${base}_材料.csv',
        bytes: materialCsvBytes(
          plan,
          sourceName: request.sourceName,
          summary: summary,
        ),
      ),
    );
  }

  return out;
}

/// Builds the printable sheets: the PNG pages and the PDF.
///
/// The PNGs are rendered here, on the UI isolate, because `ui.PictureRecorder`
/// belongs to the engine; the PDF is handed to an isolate with the font bytes,
/// because it is pure Dart and a 25-map document is a lot of drawing.
Stream<ExportedFile> buildSheetFiles({
  required MapPlan plan,
  required ExportOptions options,
  required Uint8List fontRegular,
  required Uint8List fontBold,
  String? sourceName,
}) async* {
  final base = _safeName(options.baseName);
  final summary = BuildSummary.fromPlan(
    plan,
    shape: options.shape,
    includeReferenceRow: options.includeReferenceRow,
  );
  final tiles = blueprintTiles(plan);

  if (options.formats.contains(ExportFormat.png)) {
    if (options.pngOverview) {
      yield ExportedFile(
        name: '${base}_图纸_总览.png',
        bytes: await buildBlueprintPng(
          BlueprintPngRequest(
            plan: plan,
            cell: overviewCell(plan, options.pngCell),
            thumbnail: overviewCell(plan, options.pngCell) != options.pngCell,
            sourceName: sourceName,
          ),
        ),
      );
    }
    if (options.pngPerTile) {
      for (final tile in tiles) {
        yield ExportedFile(
          name: '${base}_图纸_第${tile.index + 1}张.png',
          bytes: await buildBlueprintPng(
            BlueprintPngRequest(
              plan: plan,
              cell: options.pngCell,
              tile: tile,
              sourceName: sourceName,
            ),
          ),
        );
      }
    }
  }

  if (options.formats.contains(ExportFormat.pdf)) {
    yield ExportedFile(
      name: '${base}_图纸.pdf',
      bytes: await Isolate.run(
        () => buildBlueprintPdf(
          BlueprintPdfRequest(
            plan: plan,
            fontRegular: fontRegular,
            fontBold: fontBold,
            summary: summary,
            sourceName: sourceName,
          ),
        ),
      ),
    );
  }
}

/// Writes one file where the platform wants it.
///
/// Desktop writes straight into [directory], which the user picked once and the
/// app remembers. Mobile has no such folder to write into — the app's own
/// storage is not somewhere a person can find the file — so each one goes
/// through the system save dialog, which is what the plan asks for and what
/// "send it to the computer afterwards" needs.
///
/// Returns where it landed, or null when the user cancelled that file.
enum ExistingFileAction { overwrite, rename, skip }

int overviewCell(MapPlan plan, int requested) =>
    ((4096 - 160) ~/ (plan.width > plan.height ? plan.width : plan.height))
        .clamp(1, requested);

Future<String?> saveExportedFile(
  ExportedFile file,
  String? directory, {
  Future<ExistingFileAction> Function(String)? onConflict,
}) async {
  if (_isDesktop && directory != null) {
    return saveToDirectory(file, directory, onConflict: onConflict);
  }

  if (_isDesktop) {
    final folder = await FilePicker.getDirectoryPath(dialogTitle: '导出到哪个文件夹');
    if (folder == null) return null;
    return saveToDirectory(file, folder, onConflict: onConflict);
  }

  final uri = await FilePicker.saveFile(
    fileName: file.name,
    bytes: file.bytes,
    mimeType: _mimeOf(file.name),
    dialogTitle: '保存 ${file.name}',
  );
  if (uri == null) return null;
  // A content:// URI from the Android picker has no path, but it is what the
  // user was shown, so it is what gets reported.
  return uri.scheme == 'file' ? uri.toFilePath() : uri.toString();
}

/// The folder exports default to when the user has not picked one.
///
/// On the desktop, Downloads if the platform will name it, otherwise the
/// documents folder. Deliberately not `.minecraft/schematics`: every launcher
/// puts its instance somewhere else, so guessing would as often as not write
/// into a folder that does not exist.
Future<String?> defaultExportDirectory() async {
  try {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) return downloads.path;
  } on Object {
    // Android and iOS do not have one; falling through is the answer.
  }
  try {
    return (await getApplicationDocumentsDirectory()).path;
  } on Object {
    return null;
  }
}

bool get _isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

String _mimeOf(String name) => switch (name.split('.').last) {
  'pdf' => 'application/pdf',
  'png' => 'image/png',
  'csv' => 'text/csv',
  _ => 'application/octet-stream',
};

/// A file name that is safe on both platforms and still says what it is.
///
/// The characters Windows forbids in a name, plus the path separators, replaced
/// rather than rejected: the name comes from a text field and a user who typed a
/// slash should get a file, not an error.
String _safeName(String value) {
  final cleaned = value
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return 'mapart';
  return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
}

/// Safe for callers without a UI: conflicts are renamed, never overwritten.
Future<String?> saveToDirectory(
  ExportedFile file,
  String directory, {
  Future<ExistingFileAction> Function(String)? onConflict,
}) async {
  var target = File('$directory${Platform.pathSeparator}${file.name}');
  if (await target.exists()) {
    final action =
        await onConflict?.call(target.path) ?? ExistingFileAction.rename;
    if (action == ExistingFileAction.skip) return null;
    if (action == ExistingFileAction.rename) {
      final dot = file.name.lastIndexOf('.');
      final stem = dot < 0 ? file.name : file.name.substring(0, dot);
      final extension = dot < 0 ? '' : file.name.substring(dot);
      var suffix = 2;
      do {
        target = File(
          '$directory${Platform.pathSeparator}$stem ($suffix)$extension',
        );
        suffix++;
      } while (await target.exists());
    }
  }
  await target.writeAsBytes(file.bytes, flush: true);
  return target.path;
}
