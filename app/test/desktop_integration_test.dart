import 'dart:async';

import 'package:build_meow/src/data/preferences.dart';
import 'package:build_meow/src/window/desktop_integration.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeHost extends DesktopHost {
  Rect rect = const Rect.fromLTWH(80, 100, 1280, 860);
  bool isMaximized = false;
  bool isVisible = true;
  bool pinned = false;
  bool failPin = false;
  Size min = const Size(760, 560);
  Completer<void>? gate;
  @override
  Future<Map<String, bool>> configure(bool enabled, bool shift) async => {
    'tray': true,
    'showHotkey': enabled,
    'floatHotkey': enabled,
  };
  @override
  Future<bool> visible() async => isVisible;
  @override
  Future<bool> maximized() async => isMaximized;
  @override
  Future<Rect> bounds() async => rect;
  @override
  Future<void> restore() async => isMaximized = false;
  @override
  Future<void> maximize() async => isMaximized = true;
  @override
  Future<void> setBounds(Rect value) async => rect = value;
  @override
  Future<void> minimum(Size size) async => min = size;
  @override
  Future<void> pin(bool value) async {
    if (value && failPin) throw StateError('pin failed');
    await gate?.future;
    pinned = value;
  }

  @override
  Future<void> hide() async => isVisible = false;
  @override
  Future<void> show() async => isVisible = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({'schema_version': 1}));
  tearDown(Preferences.flush);

  test('floating restores geometry, maximum state and topmost', () async {
    final host = FakeHost()..isMaximized = true;
    final controller = DesktopController(host: host)..available = true;
    addTearDown(controller.dispose);
    final original = host.rect;
    await controller.toggleFloating();
    expect(controller.floating, isTrue);
    expect(host.pinned, isTrue);
    expect(host.rect.size, const Size(480, 620));
    expect(host.min, const Size(360, 360));
    await controller.toggleFloating();
    expect(controller.floating, isFalse);
    expect(host.pinned, isFalse);
    expect(host.rect, original);
    expect(host.isMaximized, isTrue);
  });

  test('rapid toggles serialize instead of losing the saved bounds', () async {
    final host = FakeHost()..gate = Completer<void>();
    final controller = DesktopController(host: host)..available = true;
    addTearDown(controller.dispose);
    final first = controller.toggleFloating();
    final second = controller.toggleFloating();
    host.gate!.complete();
    await Future.wait([first, second]);
    expect(host.rect, const Rect.fromLTWH(80, 100, 1280, 860));
    expect(controller.floating, isFalse);
  });

  test(
    'partial floating failure rolls back and leaves actions usable',
    () async {
      final host = FakeHost()..failPin = true;
      final controller = DesktopController(host: host)..available = true;
      addTearDown(controller.dispose);
      await controller.toggleFloating();
      expect(controller.error, contains('pin failed'));
      expect(controller.floating, isFalse);
      expect(host.rect.size, const Size(1280, 860));
      expect(host.min, const Size(760, 560));
      host.failPin = false;
      await controller.toggleFloating();
      expect(controller.floating, isTrue);
    },
  );

  test('cannot hide without a working tray, then visibility toggles', () async {
    final host = FakeHost();
    final controller = DesktopController(host: host)..available = true;
    addTearDown(controller.dispose);
    await controller.hide();
    expect(host.isVisible, isTrue);
    expect(controller.error, contains('托盘不可用'));
    await controller.configure(
      hotkeys: false,
      shift: true,
      minimizeOnClose: true,
    );
    expect(controller.showHotkeyReady, isFalse);
    expect(controller.shortcutPrefix, 'Ctrl+Alt+Shift');
    expect(await Preferences.loadDesktopOptions(), {
      'hotkeys': false,
      'shift': true,
      'closeToTray': true,
    });
    await controller.toggleVisibility();
    expect(host.isVisible, isFalse);
    await controller.handleAction('show');
    expect(host.isVisible, isTrue);
  });
}
