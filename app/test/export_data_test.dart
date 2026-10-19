import 'package:build_meow/src/data/export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapart_core/mapart_core.dart';

import 'plan_support.dart';

/// The export path, end to end and without a window: a plan in, files out, and
/// every schematic read back with core's own reader.
///
/// This is the test that says the app's export is wired to the same structure
/// the core round-trip tests prove correct. It does not re-check the bit
/// packing — `structure_selfcheck_test.dart` does that — it checks that what the
/// page hands the writers is the build and not something assembled twice.
void main() {
  late MapPlan plan;

  setUpAll(() {
    plan = buildTestResult().plan;
  });

  List<ExportedFile> build({ExportOptions? options}) => buildDataFiles(
    DataExportRequest(
      plan: plan,
      options: options ?? const ExportOptions(),
      sourceName: 'cat.png',
    ),
  );

  ExportedFile fileEnding(List<ExportedFile> files, String extension) =>
      files.firstWhere((file) => file.name.endsWith(extension));

  test('the default options write a litematic, a schem and a csv', () {
    final files = build();
    final names = files.map((file) => file.name).toList();

    expect(names.where((name) => name.endsWith('.litematic')), hasLength(1));
    expect(names.where((name) => name.endsWith('.schem')), hasLength(1));
    expect(names.where((name) => name.endsWith('.csv')), hasLength(1));
    expect(files.every((file) => file.size > 0), isTrue);
  });

  test('the litematic reads back as exactly the structure that was built', () {
    final bytes = fileEnding(build(), '.litematic').bytes;
    final read = readLitematic(bytes);
    final expected = buildStructure(plan);

    expect(read.sizeX, expected.sizeX);
    expect(read.sizeY, expected.sizeY);
    expect(read.sizeZ, expected.sizeZ);
    expect(read.cells, expected.cells);
    expect(
      read.palette.map((state) => state.toBlockStateString()),
      expected.palette.map((state) => state.toBlockStateString()),
    );
  });

  test('the schem reads back as the same structure', () {
    final files = build();
    final fromLitematic = readLitematic(fileEnding(files, '.litematic').bytes);
    final fromSchem = readSpongeSchematic(fileEnding(files, '.schem').bytes);

    expect(fromSchem.sizeX, fromLitematic.sizeX);
    expect(fromSchem.sizeY, fromLitematic.sizeY);
    expect(fromSchem.sizeZ, fromLitematic.sizeZ);
    expect(fromSchem.cells, fromLitematic.cells);
    expect(
      fromSchem.palette.map((state) => state.toBlockStateString()),
      fromLitematic.palette.map((state) => state.toBlockStateString()),
    );
  });

  test('solid fills the columns, so the file holds far more blocks', () {
    final surface = readLitematic(fileEnding(build(), '.litematic').bytes);
    final solid = readLitematic(
      fileEnding(
        build(options: const ExportOptions(shape: ExportShape.solid)),
        '.litematic',
      ).bytes,
    );

    expect(solid.sizeX, surface.sizeX);
    expect(solid.sizeY, surface.sizeY);
    expect(solid.sizeZ, surface.sizeZ);
    expect(solid.nonAirBlocks, greaterThan(surface.nonAirBlocks));
    // A surface column is one block; a solid one is every layer under it.
    expect(surface.nonAirBlocks, plan.totalBlocks + plan.width);
  });

  test('turning the reference row off makes the projection the map area', () {
    final without = readLitematic(
      fileEnding(
        build(options: const ExportOptions(includeReferenceRow: false)),
        '.litematic',
      ).bytes,
    );

    // One row fewer in Z, and the map's own first row is now the structure's
    // first row.
    expect(without.sizeZ, plan.height);
    expect(without.nonAirBlocks, plan.totalBlocks);
  });

  test('a file name with a path separator is cleaned rather than rejected', () {
    final files = build(options: const ExportOptions(baseName: 'a/b:c'));

    expect(files, isNotEmpty);
    for (final file in files) {
      expect(file.name, isNot(contains('/')));
      expect(file.name, isNot(contains(':')));
      expect(file.name, startsWith('a_b_c'));
    }
  });

  test('the formats asked for are the only ones written', () {
    final onlyCsv = build(
      options: const ExportOptions(formats: {ExportFormat.csv}),
    );

    expect(onlyCsv, hasLength(1));
    expect(onlyCsv.single.name, endsWith('.csv'));
  });

  test('the file names carry the map grid and the Chinese extension', () {
    final names = build().map((file) => file.name).toSet();

    expect(names, contains('mapart_1x1.litematic'));
    expect(names, contains('mapart_1x1.schem'));
    expect(names, contains('mapart_材料.csv'));
  });
}
