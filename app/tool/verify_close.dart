import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build_meow/main.dart' as app;
import 'package:build_meow/src/app.dart';
import 'package:build_meow/src/data/preferences.dart';
import 'package:build_meow/src/window/desktop_integration.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show IconButton;
import 'package:window_manager/window_manager.dart';

/// Exercise the real title-bar hit test and native teardown in release mode.
/// The parent script must also check process exit; reaching the click is not a
/// successful shutdown. All settings are isolated from the user's profile.
Future<void> main() async {
  final scenario = Platform.environment['BUILD_MEOW_CLOSE_SCENARIO']!;
  final directory = Directory(Platform.environment['BUILD_MEOW_CLOSE_DIR']!);
  await app.initializeWindow(persistPreferences: false);
  await Preferences.initializeStorage(directory);
  await desktop.initialize();
  final errors = <String>[];
  FlutterError.onError = (details) {
    errors.add(details.exceptionAsString());
    FlutterError.presentError(details);
  };
  final semantics = WidgetsBinding.instance.ensureSemantics();
  runApp(const ProviderScope(child: BuildMeowApp()));
  await Future<void>.delayed(const Duration(seconds: 1));
  if (scenario == 'floating') await desktop.toggleFloating();
  if (scenario == 'maximized') await windowManager.maximize();
  if (scenario == 'tray') await desktop.configure(minimizeOnClose: true);
  await Future<void>.delayed(const Duration(milliseconds: 300));

  Element? closeButton;
  void visit(Element element) {
    final widget = element.widget;
    if (widget is IconButton && widget.tooltip == '关闭') {
      closeButton = element;
    } else {
      element.visitChildElements(visit);
    }
  }

  visit(WidgetsBinding.instance.rootElement!);
  final box = closeButton!.findRenderObject()! as RenderBox;
  final position = box.localToGlobal(box.size.center(Offset.zero));
  final report = File('${directory.path}/report.json');
  await report.writeAsString(
    jsonEncode({'scenario': scenario, 'errors': errors}),
  );
  // Pointer events exercise the actual button and its surrounding drag area.
  GestureBinding.instance.handlePointerEvent(
    PointerDownEvent(pointer: 1, position: position),
  );
  await Future<void>.delayed(const Duration(milliseconds: 100));
  // Queue a real file write immediately before releasing the close button.
  unawaited(Preferences.saveThemeMode('dark'));
  GestureBinding.instance.handlePointerEvent(
    PointerUpEvent(pointer: 1, position: position),
  );
  if (scenario == 'tray') {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (await windowManager.isVisible()) {
      throw StateError('Close-to-tray did not hide the window');
    }
    await desktop.show();
    await report.writeAsString(
      jsonEncode({
        'scenario': scenario,
        'errors': errors,
        'trayRecovered': true,
      }),
    );
    await desktop.handleAction('exit');
  }
  // Keep the semantics handle alive until native teardown, as in a real app.
  await Future<void>.delayed(const Duration(seconds: 20));
  semantics.dispose();
  throw StateError('The close action did not terminate the process');
}
