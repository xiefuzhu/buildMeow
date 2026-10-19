import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_meow/src/data/export.dart';
import 'package:build_meow/src/data/export_job.dart';
import 'package:build_meow/src/data/material_csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapart_core/mapart_core.dart';

import 'plan_support.dart';

void main() {
  final plan = buildTestResult().plan;
  test('memory preflight rejects before materialising a cuboid', () {
    expect(
      () => buildDataFiles(
        DataExportRequest(
          plan: plan,
          options: const ExportOptions(formats: {ExportFormat.litematic}),
          memoryBudget: 1,
        ),
      ),
      throwsStateError,
    );
  });
  test(
    'selected build quantities are used in CSV, including reference row',
    () {
      final summary = BuildSummary.fromPlan(
        plan,
        shape: ExportShape.solid,
        includeReferenceRow: true,
      );
      final text = materialCsv(plan, summary: summary);
      final lines = text.split('\r\n');
      final quantityColumn = lines.first.split(',').indexOf('数量');
      var counted = 0;
      for (final row in lines.skip(1).take(plan.blocks.length)) {
        counted += int.parse(row.split(',')[quantityColumn]);
      }
      expect(
        counted,
        buildStructure(plan, shape: ExportShape.solid).nonAirBlocks,
      );
    },
  );
  test(
    'independent CSV parser reads header semantics and quoted source names',
    () async {
      // Python's standard csv implementation supplies an independent format
      // check in this Windows development environment; Dart assertions below
      // cover the ordinary package test path without external dependencies.
      final directory = await Directory.systemTemp.createTemp(
        'build-meow-csv-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/materials.csv');
      await file.writeAsBytes(
        materialCsvBytes(plan, sourceName: 'cat,"quoted"\nnext.png'),
      );
      final parsed = await Process.run('python', [
        '-c',
        'import csv,json,sys; r=list(csv.DictReader(open(sys.argv[1],encoding="utf-8-sig",newline=""))); print(json.dumps(r,ensure_ascii=True))',
        file.path,
      ]);
      expect(parsed.exitCode, 0, reason: '${parsed.stderr}');
      final rows = jsonDecode(parsed.stdout as String) as List<dynamic>;
      final first = rows.first as Map<String, dynamic>;
      expect(first['方块ID'], plan.blocks.first.blockId);
      expect(first['方块状态'], plan.blocks.first.blockState);
      expect(
        (rows.last as Map<String, dynamic>)['方块状态'],
        'cat,"quoted"\nnext.png',
      );
    },
  );
  test('a file conflict defaults to rename and never overwrites', () async {
    final directory = await Directory.systemTemp.createTemp('build-meow-save-');
    addTearDown(() => directory.delete(recursive: true));
    final original = File('${directory.path}/art.csv');
    await original.writeAsString('original');
    final file = ExportedFile(
      name: 'art.csv',
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    final path = await saveToDirectory(file, directory.path);
    expect(await original.readAsString(), 'original');
    expect(path, endsWith('art (2).csv'));
    expect(await File(path!).readAsBytes(), [1, 2, 3]);
    expect(
      await saveToDirectory(
        file,
        directory.path,
        onConflict: (_) async => ExistingFileAction.skip,
      ),
      isNull,
    );
  });
  test('one failed save does not discard successful files', () async {
    final result = await executeExport(
      plan: plan,
      options: const ExportOptions(
        formats: {ExportFormat.litematic, ExportFormat.csv},
      ),
      loadFont: (_) async => Uint8List(0),
      save: (file) async {
        if (file.name.endsWith('.litematic')) {
          throw const FileSystemException('disk full');
        }
        return 'saved/${file.name}';
      },
    );
    expect(result.files.where((f) => f.error != null), hasLength(1));
    expect(result.files.where((f) => f.path != null), hasLength(1));
  });
  test('export results retain sizes and states without file buffers', () async {
    final expectedSizes = <String, int>{};
    final result = await executeExport(
      plan: plan,
      options: const ExportOptions(
        formats: {ExportFormat.litematic, ExportFormat.schem, ExportFormat.csv},
      ),
      loadFont: (_) => throw StateError('data exports do not need fonts'),
      save: (file) async {
        expectedSizes[file.name] = file.bytes.length;
        if (file.name.endsWith('.litematic')) {
          expect(readLitematic(file.bytes).sizeX, plan.width);
          return 'saved/${file.name}';
        }
        if (file.name.endsWith('.schem')) {
          expect(readSpongeSchematic(file.bytes).sizeX, plan.width);
          throw const FileSystemException('disk full');
        }
        return null;
      },
    );
    expect(result.files, hasLength(3));
    expect(result.files.map((file) => file.status), ['已保存', '失败', '已取消']);
    for (final file in result.files) {
      expect(file, isA<ExportFileResult>());
      expect(file.size, expectedSizes[file.name]);
    }
    expect(result.totalBytes, expectedSizes.values.reduce((a, b) => a + b));
    expect(result.warnings, contains('部分文件未保存，请查看每个文件的状态。'));
  });

  test(
    'earlier files are saved before a later format fails to generate',
    () async {
      final events = <String>[];
      final result = await executeExport(
        plan: plan,
        options: const ExportOptions(
          formats: {ExportFormat.csv, ExportFormat.pdf},
        ),
        loadFont: (_) async {
          events.add('font');
          throw const FileSystemException('font unavailable');
        },
        save: (file) async {
          events.add('save');
          expect(file.bytes, isNotEmpty);
          return 'saved/${file.name}';
        },
      );
      expect(events, ['save', 'font']);
      expect(result.files, hasLength(2));
      expect(result.files.first.path, isNotNull);
      expect(result.files.last.error, contains('font unavailable'));
      expect(result.files.last.size, 0);
    },
  );

  testWidgets('PNG sheets save individually without loading PDF fonts', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final names = <String>[];
      final sizes = <int>[];
      final result = await executeExport(
        plan: plan,
        options: const ExportOptions(formats: {ExportFormat.png}, pngCell: 1),
        loadFont: (_) => throw StateError('PNG should not load PDF font bytes'),
        save: (file) async {
          names.add(file.name);
          sizes.add(file.bytes.length);
          expect(file.bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
          return 'saved/${file.name}';
        },
      );
      expect(names, ['mapart_图纸_总览.png', 'mapart_图纸_第1张.png']);
      expect(result.files.map((file) => file.size), sizes);
      expect(result.files.every((file) => file.path != null), isTrue);
    });
  });

  test('Sponge export carries the required typed root and data version', () {
    final bytes = buildDataFiles(
      DataExportRequest(
        plan: plan,
        options: const ExportOptions(formats: {ExportFormat.schem}),
      ),
    ).single.bytes;
    final root = readNbt(bytes).root;
    expect((root['Version'] as NbtInt).value, 2);
    expect((root['DataVersion'] as NbtInt).value, plan.dataVersion);
    expect(root['Width'], isA<NbtShort>());
    expect(root['Height'], isA<NbtShort>());
    expect(root['Length'], isA<NbtShort>());
    expect(root['BlockData'], isA<NbtByteArray>());
    expect((root['Offset'] as NbtIntArray).value, [0, 0, 0]);
  });
}
