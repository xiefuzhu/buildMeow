import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../data/preferences.dart';
import 'desktop_integration.dart';

/// Window operations, in one place so the rest of the app never has to ask
/// whether it is running inside a real window.
///
/// [enabled] is set once by `main` after the window has been configured. It is
/// deliberately false everywhere else, including widget tests: those never run
/// `main`, so every call here turns into a no-op instead of a platform-channel
/// exception, and the custom title bar can be built and tested without a window.
abstract final class WindowControls {
  static bool enabled = false;
  static bool _closing = false;
  static void Function(String)? onCloseError;

  static Future<void> protectPendingSaves() async {
    if (!enabled) return;
    await windowManager.setPreventClose(true);
    windowManager.addListener(_SaveBeforeClose());
  }

  /// Whether this build is running on a desktop platform at all.
  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static Future<void> minimize() async {
    if (!enabled) return;
    await windowManager.minimize();
  }

  static Future<void> toggleMaximize() async {
    if (!enabled) return;
    if (await windowManager.isMaximized()) {
      await windowManager.restore();
    } else {
      await windowManager.maximize();
    }
  }

  static Future<void> close() async {
    final qa =
        kDebugMode && Platform.environment['BUILD_MEOW_NATIVE_QA'] == '1';
    if (qa) {
      debugPrint(
        'VERIFY CLOSE: enabled=$enabled closing=$_closing saving=${Preferences.saving.value} error=${Preferences.error.value}',
      );
    }
    if (!enabled || _closing) return;
    _closing = true;
    try {
      await Preferences.flush();
      if (qa) debugPrint('VERIFY CLOSE: preferences flushed');
      await windowManager.destroy();
      if (qa) debugPrint('VERIFY CLOSE: window destroyed');
    } on Object catch (reason) {
      if (qa) debugPrint('VERIFY CLOSE FAILED: $reason');
      _closing = false;
      // An explicit tray exit can fail while hidden. Bring the settings error
      // back into reach so the user can retry saving.
      await windowManager.show();
      await windowManager.focus();
      onCloseError?.call('设置保存失败，窗口尚未关闭。请在设置页重试保存。$reason');
    }
  }

  static const _dragChannel = MethodChannel('build_meow/window_drag');

  /// Begin a nonblocking move using native screen coordinates on Windows.
  static Future<bool> beginDrag() async {
    if (!enabled) return false;
    if (Platform.isWindows) {
      return await _dragChannel.invokeMethod<bool>('begin') ?? false;
    }
    await windowManager.startDragging();
    return false;
  }

  static Future<void> updateDrag() async {
    if (enabled && Platform.isWindows) {
      await _dragChannel.invokeMethod<void>('update');
    }
  }

  static Future<void> endDrag() async {
    if (enabled && Platform.isWindows) {
      await _dragChannel.invokeMethod<void>('end');
    }
  }

  static Future<bool> isMaximized() async {
    if (!enabled) return false;
    return windowManager.isMaximized();
  }

  /// Registers [listener] for window state changes, or does nothing when there
  /// is no window to listen to.
  static void addListener(WindowListener listener) {
    if (!enabled) return;
    windowManager.addListener(listener);
  }

  static void removeListener(WindowListener listener) {
    if (!enabled) return;
    windowManager.removeListener(listener);
  }
}

class _SaveBeforeClose extends WindowListener {
  @override
  void onWindowClose() {
    desktop.requestClose();
  }
}
