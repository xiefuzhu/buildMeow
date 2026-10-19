import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:path_provider/path_provider.dart';

import 'src/data/preferences.dart';

import 'src/app.dart';
import 'src/window/window_controls.dart';
import 'src/window/desktop_integration.dart';

Future<void> main() async {
  await initializeWindow();
  await desktop.initialize();
  runApp(const ProviderScope(child: BuildMeowApp()));
}

/// Shared startup for the app and the native desktop verification entry point.
Future<void> initializeWindow({bool persistPreferences = true}) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows && persistPreferences) {
    await Preferences.initializeStorage(await getApplicationSupportDirectory());
  }

  // The window is created here rather than in `windows/runner/main.cpp` so the
  // size and the frameless style live next to the Dart code that depends on
  // them. `TitleBarStyle.hidden` removes the Windows caption and keeps the
  // resize frame, and `AppTitleBar` puts back what it removed.
  if (WindowControls.isDesktop) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1280, 860),
      minimumSize: Size(760, 560),
      center: true,
      title: '建喵!',
      titleBarStyle: TitleBarStyle.hidden,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    WindowControls.enabled = true;
    await WindowControls.protectPendingSaves();
  }
}
