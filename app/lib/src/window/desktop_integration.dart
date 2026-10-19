import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../data/preferences.dart';
import 'window_controls.dart';

/// One controller owns the window so rapid tray/hotkey actions cannot race.
final desktop = DesktopController();

class DesktopHost {
  static const channel = MethodChannel('build_meow/desktop');

  Future<Map<String, Object?>> configure(bool enabled, bool shift) async =>
      Map<String, Object?>.from(
        await channel.invokeMethod<Map<Object?, Object?>>('configure', {
              'enabled': enabled,
              'shift': shift,
            }) ??
            {},
      );
  Future<bool> visible() => windowManager.isVisible();
  Future<bool> maximized() => windowManager.isMaximized();
  Future<Rect> bounds() => windowManager.getBounds();
  Future<void> restore() => windowManager.restore();
  Future<void> maximize() => windowManager.maximize();
  Future<void> setBounds(Rect bounds) => windowManager.setBounds(bounds);
  Future<void> minimum(Size size) => windowManager.setMinimumSize(size);
  Future<void> pin(bool value) => windowManager.setAlwaysOnTop(value);
  Future<void> hide() => windowManager.hide();
  Future<void> show() async {
    await windowManager.show();
    if (await windowManager.isMinimized()) await windowManager.restore();
    if (Platform.isWindows) await channel.invokeMethod<void>('fitWorkArea');
    await windowManager.focus();
  }
}

class DesktopController extends ChangeNotifier {
  DesktopController({DesktopHost? host}) : _host = host ?? DesktopHost();
  final DesktopHost _host;
  bool available = false;
  bool floating = false;
  bool busy = false;
  bool trayReady = false;
  bool showHotkeyReady = false;
  bool floatHotkeyReady = false;
  bool hotkeysEnabled = true;
  bool extraShift = false;
  bool closeToTray = false;
  int showHotkeyError = 0;
  int floatHotkeyError = 0;
  String? error;
  Rect? _normalBounds;
  bool _wasMaximized = false;
  Future<void>? _pending;

  String get shortcutPrefix => extraShift ? 'Ctrl+Alt+Shift' : 'Ctrl+Alt';

  Future<void> initialize() async {
    if (!WindowControls.enabled || !Platform.isWindows) return;
    available = true;
    DesktopHost.channel.setMethodCallHandler((call) async {
      if (call.method == 'action') await handleAction(call.arguments as String);
    });
    final options = await Preferences.loadDesktopOptions();
    hotkeysEnabled = options['hotkeys'] ?? true;
    extraShift = options['shift'] ?? false;
    closeToTray = options['closeToTray'] ?? false;
    await configure();
  }

  Future<void> _run(Future<void> Function() action) {
    if (!available) return Future.value();
    final previous = _pending ?? Future<void>.value();
    final operation = previous.then((_) async {
      busy = true;
      error = null;
      notifyListeners();
      try {
        await action();
      } on Object catch (reason) {
        error = '桌面操作失败：$reason';
      } finally {
        busy = false;
        notifyListeners();
      }
    });
    _pending = operation;
    unawaited(
      operation.then((_) {
        if (identical(_pending, operation)) _pending = null;
      }),
    );
    return operation;
  }

  Future<void> configure({bool? hotkeys, bool? shift, bool? minimizeOnClose}) =>
      _run(() async {
        hotkeysEnabled = hotkeys ?? hotkeysEnabled;
        extraShift = shift ?? extraShift;
        closeToTray = minimizeOnClose ?? closeToTray;
        final status = await _host.configure(hotkeysEnabled, extraShift);
        trayReady = status['tray'] == true;
        showHotkeyReady = status['showHotkey'] == true;
        floatHotkeyReady = status['floatHotkey'] == true;
        showHotkeyError = status['showError'] as int? ?? 0;
        floatHotkeyError = status['floatError'] as int? ?? 0;
        if (!trayReady) {
          await _host.show();
          error = '托盘暂不可用，窗口已显示；关闭按钮将直接退出。可重试注册。';
        } else if (hotkeysEnabled && (!showHotkeyReady || !floatHotkeyReady)) {
          error =
              '部分快捷键注册失败（显示：$showHotkeyError，悬浮：$floatHotkeyError），'
              '1409 表示组合键被占用。可换用组合键或重试；托盘仍可使用。';
        }
        await Preferences.saveDesktopOptions({
          'hotkeys': hotkeysEnabled,
          'shift': extraShift,
          'closeToTray': closeToTray,
        });
      });

  Future<void> show() => _run(_host.show);

  Future<void> hide() => _run(_hide);

  Future<void> _hide() async {
    if (!trayReady) throw StateError('托盘不可用，请使用最小化');
    await _host.hide();
  }

  Future<void> toggleVisibility() => _run(() async {
    if (await _host.visible()) {
      await _hide();
    } else {
      await _host.show();
    }
  });

  Future<void> toggleFloating() => _run(() async {
    if (!floating) {
      await _host.show();
      _wasMaximized = await _host.maximized();
      if (_wasMaximized) await _host.restore();
      _normalBounds = await _host.bounds();
      try {
        await _host.minimum(const Size(360, 360));
        // Keep the current top-left on its monitor rather than recentering on
        // the primary screen. Windows constrains the minimum resize frame.
        await _host.setBounds(
          Rect.fromLTWH(_normalBounds!.left, _normalBounds!.top, 480, 620),
        );
        await _host.pin(true);
        await _host.show();
        floating = true;
      } on Object {
        await _restoreNormal();
        rethrow;
      }
    } else {
      await _restoreNormal();
      floating = false;
      await _host.show();
    }
  });

  Future<void> _restoreNormal() async {
    await _host.pin(false);
    await _host.minimum(const Size(760, 560));
    if (_normalBounds != null) await _host.setBounds(_normalBounds!);
    if (_wasMaximized) await _host.maximize();
  }

  Future<void> handleAction(String action) async {
    switch (action) {
      case 'show':
        await show();
      case 'hide':
        await hide();
      case 'toggleVisibility':
        await toggleVisibility();
      case 'float':
        await toggleFloating();
      case 'trayChanged':
        await configure();
      case 'exit':
        await WindowControls.close();
    }
  }

  Future<void> requestClose() =>
      closeToTray && trayReady ? hide() : WindowControls.close();
}
