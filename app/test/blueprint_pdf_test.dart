import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_meow/src/data/blueprint_pdf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapart_core/mapart_core.dart';

import 'plan_support.dart';

/// Read the emitted PDF's compressed content, independently of its widgets.
List<String> pageCommands(Uint8List bytes) {
  final source = latin1.decode(bytes);
  final streams = <String>[];
  for (final match in RegExp(
    r'stream\r?\n(.*?)\r?\nendstream',
    dotAll: true,
  ).allMatches(source)) {
    final raw = latin1.encode(match.group(1)!);
    String commands;
    try {
      commands = latin1.decode(zlib.decode(raw));
    } on FormatException {
      commands = latin1.decode(raw);
    }
    if (commands.contains('BT') && commands.contains(' re ')) {
      streams.add(commands);
    }
  }
  return streams;
}

MapPlan pdfFixture(ArtKind kind) {
  final request = buildTestRequest();
  final version = request.versionTable.latest;
  var palette = Palette.select(request.colorTable, version.blockSetAlias);
  if (kind == ArtKind.blockPixels) {
    palette = palette.withBlockColors({
      for (final entry in palette.entries)
        entry.blockId:
            (entry.tone(ShadeTier.normal).r << 16) |
            (entry.tone(ShadeTier.normal).g << 8) |
            entry.tone(ShadeTier.normal).b,
    });
  }
  const width = 256;
  const height = 128;
  final choices = Int32List(width * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      choices[y * width + x] =
          (x ~/ 16 + (y ~/ 16) * 8 + (x ~/ 128) * 17) % palette.length;
    }
  }
  return buildMapPlan(
    solution: HeightSolution(
      width: width,
      height: height,
      heights: Int32List(width * height)..fillRange(0, width * height, 64),
      referenceRowHeight: 64,
      minHeight: 64,
      maxHeight: 64,
      totalCost: 0,
      windowHits: 0,
      warnings: const [],
      fitsWorld: true,
    ),
    quantized: QuantizedImage(
      width: width,
      height: height,
      choiceIndices: [for (var i = 0; i < 3; i++) choices],
      choiceCosts: [for (var i = 0; i < 3; i++) Float32List(width * height)],
      dithered: false,
    ),
    palette: palette,
    version: version,
    artKind: kind,
  );
}

void main() {
  for (final kind in ArtKind.values) {
    test(
      '$kind overview and tiles fill cells and stroke chunk boundaries',
      () async {
        final plan = pdfFixture(kind);
        final bytes = await buildBlueprintPdf(
          BlueprintPdfRequest(
            plan: plan,
            fontRegular: File('assets/fonts/NotoSansSC-Regular.ttf')
                .readAsBytesSync(),
            fontBold: File('assets/fonts/NotoSansSC-Bold.ttf')
                .readAsBytesSync(),
            sourceName: 'PDF regression mosaic.png',
          ),
        );
        if (const bool.fromEnvironment('PDF_QA')) {
          const label = String.fromEnvironment(
            'PDF_QA_LABEL',
            defaultValue: 'after',
          );
          final prefix = 'build/qa/pdf_${label}_${kind.name}';
          Directory('build/qa').createSync(recursive: true);
          File('$prefix.pdf').writeAsBytesSync(bytes);
          File('$prefix.json').writeAsStringSync(
            jsonEncode({
              'kind': kind.name,
              'width': plan.width,
              'height': plan.height,
              'materials': plan.blocks.map((b) => b.blockState).toList(),
              'samples': [
                for (final y in [8, 56, 120])
                  for (final x in [8, 56, 120, 136, 184, 248])
                    {
                      'x': x,
                      'y': y,
                      'rgb': [
                        plan.colorAt(x, y).r,
                        plan.colorAt(x, y).g,
                        plan.colorAt(x, y).b,
                      ],
                    },
              ],
            }),
          );
        }
        final streams = pageCommands(bytes);
        final filledCells = RegExp(r'\bre\s+f\b');
        final grids = streams
            .where((s) => filledCells.allMatches(s).length >= 128)
            .toList();
        expect(
          grids,
          hasLength(3),
          reason: 'overview and both tiles must paint their own cells',
        );
        expect(
          grids.where((s) => RegExp(r'\bS\b').hasMatch(s)),
          hasLength(2),
          reason: 'both tile pages must stroke their chunk paths',
        );
      },
    );
  }
}
