import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:build_meow/main.dart' as app;
import 'package:build_meow/src/app.dart';
import 'package:build_meow/src/state/project.dart';
import 'package:build_meow/src/window/window_controls.dart';
import 'package:build_meow/src/widgets/blueprint_viewer.dart';
import 'package:build_meow/src/data/preferences.dart';
import 'package:build_meow/src/data/export.dart';
import 'package:build_meow/src/pages/settings_page.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'package:material_ui/material_ui.dart' show NavigationRail, ThemeMode;
import 'package:mapart_core/mapart_core.dart' show ExportShape;

import 'package:flutter/services.dart';
import 'package:build_meow/src/window/desktop_integration.dart';

import 'desktop_feature_checks.dart';

Element? findElement(bool Function(Widget) matches) {
  Element? found;
  void visit(Element element) {
    if (found != null) return;
    if (matches(element.widget)) {
      found = element;
    } else {
      element.visitChildElements(visit);
    }
  }

  visit(WidgetsBinding.instance.rootElement!);
  return found;
}

/// Native smoke test without flutter_tester or the integration-test transport.
/// flutter run -d windows -t tool/verify_desktop.dart --no-pub
Future<void> main() async {
  // This native test must leave the user's real preferences untouched.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({'schema_version': 1});
  await app.initializeWindow(persistPreferences: false);
  await desktop.initialize();
  final container = ProviderContainer();
  final key = GlobalKey();
  final errors = <String>[];
  FlutterError.onError = (details) {
    errors.add(details.exceptionAsString());
    FlutterError.presentError(details);
  };
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(key: key, child: const BuildMeowApp()),
    ),
  );
  await Future<void>.delayed(const Duration(seconds: 1));
  final preferencePhase = Platform.environment['BUILD_MEOW_PREF_PHASE'];
  if (preferencePhase != null) {
    await Preferences.initializeStorage(
      Directory(Platform.environment['BUILD_MEOW_PREFS_QA_DIR']!),
    );
    if (preferencePhase == 'write') {
      container
          .read(settingsProvider.notifier)
          .update(
            (s) =>
                s.copyWith(mapsX: 2, artKind: ArtKind.mapItem, flatMap: true),
          );
      container.read(themeModeProvider.notifier).set(ThemeMode.dark);
      container
          .read(exportDirectoryProvider.notifier)
          .set('build/qa/saved_exports');
      await Preferences.saveExportOptions(
        const ExportOptions(
          formats: {ExportFormat.pdf, ExportFormat.csv},
          shape: ExportShape.surface,
          baseName: 'remember_me',
          referenceRows: {ArtKind.mapItem: false},
        ),
      );
      await Preferences.flush();
    } else {
      await container.read(settingsProvider.notifier).restore();
      await container.read(themeModeProvider.notifier).restore();
      await container.read(exportDirectoryProvider.notifier).restore();
      final settings = container.read(settingsProvider);
      final options = await Preferences.loadExportOptions();
      if (settings.mapsX != 2 ||
          !settings.flatMap ||
          settings.artKind != ArtKind.mapItem ||
          container.read(themeModeProvider) != ThemeMode.dark ||
          container.read(exportDirectoryProvider) != 'build/qa/saved_exports' ||
          options?.baseName != 'remember_me' ||
          options?.formats.length != 2 ||
          options?.referenceRows[ArtKind.mapItem] != false) {
        throw StateError('Preferences did not survive a fresh native process');
      }
    }
    Directory('build/qa').createSync(recursive: true);
    File('build/qa/native_preferences_$preferencePhase.json').writeAsStringSync(
      jsonEncode({'passed': true, 'phase': preferencePhase, 'pid': pid}),
    );
    await WindowControls.close();
    return;
  }
  final report = <String, Object?>{};
  try {
    final handle = WidgetsBinding.instance.ensureSemantics();
    stdout.writeln('VERIFY: semantics enabled');
    final image = img.Image(width: 64, height: 32, numChannels: 3);
    for (var y = 0; y < 32; y++) {
      for (var x = 0; x < 64; x++) {
        image.setPixelRgb(x, y, x * 4, y * 8, 140);
      }
    }
    container
        .read(sourceImageProvider.notifier)
        .set(
          SourceImage(
            name: 'gradient.png',
            bytes: img.encodePng(image),
            width: 64,
            height: 32,
          ),
        );
    for (final kind in ArtKind.values) {
      stdout.writeln('VERIFY: generating ${kind.name}');
      container.read(settingsProvider.notifier).setArtKind(kind);
      await container.read(resultProvider.notifier).generate();
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (container.read(resultProvider).isLoading &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final result = container.read(resultProvider);
      final data = result.value;
      if (result.hasError ||
          data == null ||
          data.artKind != kind ||
          !data.fitsWorld) {
        throw StateError('generation failed: ${result.error}');
      }
      if (kind == ArtKind.blockPixels && data.blockHeightSpan != 1) {
        throw StateError('block pixel construction is not flat');
      }
      report[kind.name] = {
        'width': data.width,
        'height': data.height,
        'layers': data.blockHeightSpan,
        'blocks': data.blocksUsed,
      };
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    container.read(settingsProvider.notifier).setFlatMap(true);
    await container.read(resultProvider.notifier).generate();
    while (container.read(resultProvider).isLoading) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final flat = container.read(resultProvider).value;
    if (flat == null || !flat.plan.isFlatMap || flat.blockHeightSpan != 1) {
      throw StateError('single-layer map generation failed');
    }
    report['flatMap'] = {
      'layers': flat.blockHeightSpan,
      'blocks': flat.blocksUsed,
    };
    for (var attempt = 0; attempt < 3; attempt++) {
      stdout.writeln('VERIFY: maximize/restore ${attempt + 1}');
      await windowManager.maximize();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await windowManager.unmaximize();
      await windowManager.setSize(const Size(850, 680));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await windowManager.setSize(const Size(1400, 900));
    await Future<void>.delayed(const Duration(milliseconds: 400));

    // The debug runner supplies controlled screen points to the same drag
    // handlers used in production, without moving the user's cursor.
    final drag = await const MethodChannel('build_meow/window_drag')
        .invokeMapMethod<String, dynamic>('verify');
    if (drag?['passed'] != true) {
      throw StateError('native drag verification failed: $drag');
    }
    report['dragSamples'] = drag!['samples'];
    report['dragPassed'] = true;
    report['dragRestoresMaximized'] = drag['restoredMaximized'];
    await Future<void>.delayed(const Duration(milliseconds: 150));

    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final screenshot = await boundary.toImage();
    final png = await screenshot.toByteData(format: ui.ImageByteFormat.png);
    screenshot.dispose();
    final output = Directory('build/qa')..createSync(recursive: true);
    File('${output.path}/native_workbench.png')
        .writeAsBytesSync(png!.buffer.asUint8List());

    final rail =
        findElement((w) => w is NavigationRail)!.widget as NavigationRail;
    rail.onDestinationSelected!(1);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final viewerElement = findElement((w) => w is BlueprintViewer)!;
    final viewer = viewerElement.findRenderObject()! as RenderBox;
    final paintElement = findElement(
      (w) => w is CustomPaint && w.painter is BlueprintPainter,
    )!;
    final canvas = paintElement.findRenderObject()! as RenderBox;
    final painter =
        (paintElement.widget as CustomPaint).painter! as BlueprintPainter;
    if (painter.cell * 128 > canvas.size.height + 0.01 ||
        painter.cell * 128 > canvas.size.width + 0.01 ||
        canvas.size.height > viewer.size.height ||
        canvas.size.width > viewer.size.width) {
      throw StateError('blueprint clipped: ${canvas.size} in ${viewer.size}');
    }
    final blueprintImage = await boundary.toImage();
    final blueprintPng = await blueprintImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    blueprintImage.dispose();
    File('${output.path}/native_blueprint.png')
        .writeAsBytesSync(blueprintPng!.buffer.asUint8List());
    report['blueprintFits'] = true;
    report['desktopFeatures'] = await verifyDesktopFeatures(
      boundary,
      container,
    );
    handle.dispose();
    report['resizeCycles'] = 3;
    report['frameworkErrors'] = errors;
    report['passed'] = errors.isEmpty;
  } on Object catch (error, stack) {
    report['passed'] = false;
    report['error'] = '$error';
    report['stack'] = '$stack';
  }
  Directory('build/qa').createSync(recursive: true);
  File('build/qa/native_report.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln('VERIFY REPORT: ${jsonEncode(report)}');
  await WindowControls.close();
}
