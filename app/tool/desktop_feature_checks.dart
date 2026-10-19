import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:build_meow/src/state/accessibility.dart';
import 'package:build_meow/src/window/desktop_integration.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

/// Runs against real Win32 registrations and sends real keyboard input while
/// the application is hidden. No physical cursor movement or Explorer restart.
Future<Map<String, Object?>> verifyDesktopFeatures(
  RenderRepaintBoundary boundary,
  ProviderContainer container,
) async {
  const channel = DesktopHost.channel;
  var activeShift = false;
  var injectedInputUnavailable = false;
  Future<void> waitFor(FutureOr<bool> Function() predicate) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!await predicate()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Desktop action timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  Future<void> key(String key, {bool? shift}) async {
    if (injectedInputUnavailable) {
      await channel.invokeMethod<void>('probeHotkeyMessage', key.codeUnitAt(0));
      return;
    }
    final args = [key.codeUnitAt(0), shift ?? activeShift];
    try {
      if (await channel.invokeMethod<bool>('probeKey', [...args, true]) !=
          true) {
        throw StateError('SendInput failed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } finally {
      await channel.invokeMethod<bool>('probeKey', [...args, false]);
    }
  }

  Future<void> screenshot(String name) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    File('build/qa/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  }

  await desktop.configure(hotkeys: true, shift: false);
  final defaultStatus = {
    'show': desktop.showHotkeyReady,
    'float': desktop.floatHotkeyReady,
    'showError': desktop.showHotkeyError,
    'floatError': desktop.floatHotkeyError,
  };
  if (!desktop.showHotkeyReady || !desktop.floatHotkeyReady) {
    stdout.writeln(
      'VERIFY: default shortcut status $defaultStatus; trying alternate',
    );
    activeShift = true;
    await desktop.configure(shift: true);
  }
  if (!desktop.trayReady ||
      !desktop.showHotkeyReady ||
      !desktop.floatHotkeyReady) {
    throw StateError('Tray/both hotkey presets failed: ${desktop.error}');
  }
  final original = await windowManager.getBounds();
  await desktop.hide();
  await key('M');
  await Future<void>.delayed(const Duration(milliseconds: 500));
  if (!await windowManager.isVisible()) {
    // Some desktop execution environments accept SendInput but discard all
    // injected input. Keep registration and message-dispatch checks useful,
    // explicitly recording that actual keyboard delivery needs manual QA.
    injectedInputUnavailable = true;
    stdout.writeln(
      'VERIFY: SendInput produced no hotkey; using WM_HOTKEY dispatch, physical keys remain unverified',
    );
    await key('M');
  }
  await waitFor(windowManager.isVisible);
  await key('M');
  await waitFor(() async => !await windowManager.isVisible());
  // This hotkey must work while the app has no visible/focused window.
  await key('F');
  await waitFor(() => desktop.floating && !desktop.busy);
  if (!await windowManager.isAlwaysOnTop() ||
      !await windowManager.isVisible()) {
    throw StateError('Floating window is not visible and topmost');
  }
  final small = await windowManager.getBounds();
  if ((small.width - 480).abs() > 2 || (small.height - 620).abs() > 2) {
    throw StateError('Unexpected floating bounds: $small');
  }
  await screenshot('native_floating');
  await key('F');
  await waitFor(() => !desktop.floating && !desktop.busy);
  final restored = await windowManager.getBounds();
  if (await windowManager.isAlwaysOnTop() ||
      (restored.width - original.width).abs() > 2 ||
      (restored.height - original.height).abs() > 2) {
    throw StateError('Normal bounds/topmost not restored');
  }

  await desktop.configure(hotkeys: false);
  if (await channel.invokeMethod<bool>('probeReserve', [true, activeShift]) !=
      true) {
    throw StateError('Disabled hotkeys were not released');
  }
  await desktop.configure(hotkeys: true);
  if (desktop.showHotkeyReady ||
      desktop.floatHotkeyReady ||
      desktop.error == null) {
    throw StateError('Registration conflict not reported');
  }
  await channel.invokeMethod<bool>('probeReserve', [false, activeShift]);
  await desktop.configure(shift: true);
  if (!desktop.showHotkeyReady || !desktop.floatHotkeyReady) {
    throw StateError('Alternate shortcuts failed');
  }
  await desktop.hide();
  await key('M', shift: true);
  await waitFor(windowManager.isVisible);
  await desktop.configure(shift: activeShift, minimizeOnClose: true);
  await desktop.requestClose();
  if (await windowManager.isVisible()) {
    throw StateError('Close-to-tray did not hide');
  }
  await channel.invokeMethod<void>('probeTraySelect');
  await waitFor(windowManager.isVisible);
  await channel.invokeMethod<void>('probeTrayRestart');
  await Future<void>.delayed(const Duration(milliseconds: 400));
  if (!desktop.trayReady) throw StateError('Tray reconstruction failed');
  await windowManager.maximize();
  await Future<void>.delayed(const Duration(milliseconds: 250));
  await desktop.toggleFloating();
  await desktop.toggleFloating();
  if (!await windowManager.isMaximized()) {
    throw StateError('Maximum state not restored');
  }
  await windowManager.unmaximize();
  await desktop.toggleFloating();
  await windowManager.setSize(const ui.Size(360, 360));
  container
      .read(accessibilityProvider.notifier)
      .set(textScale: 2, highContrast: true);
  await screenshot('native_floating_accessible');
  await desktop.toggleFloating();
  container
      .read(accessibilityProvider.notifier)
      .set(textScale: 1, highContrast: false);
  await desktop.configure(minimizeOnClose: false);
  return {
    'trayRegistered': true,
    'defaultShortcutStatus': defaultStatus,
    'usedExtraShift': activeShift,
    'systemHotkeyRegistration': true,
    'realGlobalKeys': !injectedInputUnavailable,
    'injectedMessageFallback': injectedInputUnavailable,
    'conflictAndAlternateKeys': true,
    'closeToTrayAndActivation': true,
    'trayReconstruction': true,
    'floatingBounds': [small.left, small.top, small.width, small.height],
    'normalBoundsRestored': true,
    'maximizedRestored': true,
    'minimumFloatingAt200Percent': true,
  };
}
