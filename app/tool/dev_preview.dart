// Throwaway entry point used to screenshot the app with a real picture loaded,
// because the file picker cannot be driven from a script.
//
//   flutter build windows --debug -t tool/dev_preview.dart
//   MEOW_IMAGE=<path> build\windows\x64\runner\Debug\build_meow.exe
import 'dart:io';
import 'dart:ui' as ui;

import 'package:build_meow/src/app.dart';
import 'package:build_meow/src/state/project.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final container = ProviderContainer();
  final path =
      Platform.environment['MEOW_IMAGE'] ??
      r'C:\Users\xiefuzhu\Pictures\B077CD3898AD5AA5511D581BD5CDFD0C.jpg';
  final bytes = File(path).readAsBytesSync();

  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final width = frame.image.width;
  final height = frame.image.height;
  frame.image.dispose();
  codec.dispose();

  container
      .read(sourceImageProvider.notifier)
      .set(
        SourceImage(
          name: path.split(Platform.pathSeparator).last,
          bytes: bytes,
          width: width,
          height: height,
        ),
      );

  if (Platform.environment['MEOW_GENERATE'] != '0') {
    // Let the first frame land before kicking off the solve, so a screenshot
    // taken during startup shows the shell rather than a blank window.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await container.read(resultProvider.notifier).generate();
      final result = container.read(resultProvider);
      stdout.writeln('--- generate ---');
      stdout.writeln('loading: ${result.isLoading}');
      if (result.hasError) {
        stdout.writeln('error: ${result.error}');
        stdout.writeln(result.stackTrace);
      }
      final data = result.value;
      if (data == null) {
        stdout.writeln('no result');
      } else {
        stdout.writeln(
          'rendered ${data.width}x${data.height} '
          'Y ${data.minHeight}..${data.maxHeight} '
          'blur dE ${data.blurredMeanError.toStringAsFixed(2)} '
          'dithered ${data.ditheredPixels} '
          'in ${data.elapsed.inMilliseconds}ms',
        );
        final p = data.rendered.pixelAt(data.width ~/ 2, data.height ~/ 2);
        stdout.writeln('centre pixel: ${p.r},${p.g},${p.b}');
        final q = data.rendered.pixelAt(0, 0);
        stdout.writeln('corner pixel: ${q.r},${q.g},${q.b}');
      }
      stdout.writeln('warnings: ${data?.warnings}');
      await stdout.flush();
    });
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const BuildMeowApp(),
    ),
  );
}
