import 'dart:isolate';
import 'dart:typed_data';

import 'package:mapart_core/mapart_core.dart';

import 'export.dart';

/// Executes a captured plan and options. Page lifetime and later edits cannot
/// change the files in this export. Results retain metadata, not file bytes.
Future<ExportResult> executeExport({
  required MapPlan plan,
  required ExportOptions options,
  required Future<Uint8List> Function(String) loadFont,
  required Future<String?> Function(ExportedFile) save,
  void Function(String)? onProgress,
  String? sourceName,
}) async {
  if (options.formats.isEmpty) throw StateError('请至少选择一种导出格式');
  final watch = Stopwatch()..start();
  final saved = <ExportFileResult>[];
  final warnings = <String>[];

  Future<void> saveOne(ExportedFile file) async {
    onProgress?.call('正在保存 ${file.name}…');
    try {
      final path = await save(file);
      saved.add(ExportFileResult(name: file.name, size: file.size, path: path));
    } on Object catch (error) {
      saved.add(
        ExportFileResult(name: file.name, size: file.size, error: '$error'),
      );
    }
  }

  // Keep the established order: data files, PNG sheets, then PDF. Only one
  // format is generated at a time, and each sheet waits for its save to finish.
  for (final format in [
    ExportFormat.litematic,
    ExportFormat.schem,
    ExportFormat.csv,
    ExportFormat.png,
    ExportFormat.pdf,
  ]) {
    if (!options.formats.contains(format)) continue;
    final selected = options.copyWith(formats: {format});
    onProgress?.call('正在生成${format.label}…');
    try {
      if (format == ExportFormat.png || format == ExportFormat.pdf) {
        final regular = format == ExportFormat.pdf
            ? await loadFont('NotoSansSC-Regular.ttf')
            : Uint8List(0);
        final bold = format == ExportFormat.pdf
            ? await loadFont('NotoSansSC-Bold.ttf')
            : Uint8List(0);
        await for (final file in buildSheetFiles(
          plan: plan,
          options: selected,
          fontRegular: regular,
          fontBold: bold,
          sourceName: sourceName,
        )) {
          await saveOne(file);
        }
      } else {
        final file = await Isolate.run(
          () => buildDataFiles(
            DataExportRequest(
              plan: plan,
              options: selected,
              sourceName: sourceName,
            ),
          ).single,
        );
        await saveOne(file);
      }
    } on Object catch (error) {
      saved.add(
        ExportFileResult(name: format.label, size: 0, error: '生成失败：$error'),
      );
    }
  }
  if (options.formats.contains(ExportFormat.png) &&
      options.pngOverview &&
      overviewCell(plan, options.pngCell) < options.pngCell) {
    warnings.add('总览为缩略图；逐张图纸保持选定分辨率。');
  }
  if (saved.any((file) => file.path == null)) {
    warnings.add('部分文件未保存，请查看每个文件的状态。');
  }
  return ExportResult(files: saved, elapsed: watch.elapsed, warnings: warnings);
}
