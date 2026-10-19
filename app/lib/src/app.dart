import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'pages/blueprint_page.dart';
import 'pages/export_page.dart';
import 'pages/home_page.dart';
import 'pages/materials_page.dart';
import 'pages/settings_page.dart';
import 'state/project.dart';
import 'state/accessibility.dart';
import 'theme.dart';
import 'widgets/title_bar.dart';
import 'window/window_controls.dart';
import 'window/desktop_integration.dart';

/// The app shell: theme, then an adaptive navigation frame.
class BuildMeowApp extends ConsumerWidget {
  const BuildMeowApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final accessibility = ref.watch(accessibilityProvider);

    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        // `dynamic_color` gives a full scheme on Android 12+ (wallpaper) and on
        // Windows (system accent). Anything else — including a Windows build
        // where the accent cannot be read — falls back to a seeded scheme, so
        // the app never ends up with an unstyled default palette.
        final lightScheme =
            lightDynamic ??
            ColorScheme.fromSeed(
              seedColor: kSeedColor,
              brightness: Brightness.light,
            );
        final darkScheme =
            darkDynamic ??
            ColorScheme.fromSeed(
              seedColor: kSeedColor,
              brightness: Brightness.dark,
            );

        return MaterialApp(
          title: '建喵!',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: AppTheme.light(
            accessibility.highContrast
                ? AppTheme.contrastScheme(Brightness.light)
                : lightScheme,
          ),
          darkTheme: AppTheme.dark(
            accessibility.highContrast
                ? AppTheme.contrastScheme(Brightness.dark)
                : darkScheme,
          ),
          highContrastTheme: AppTheme.light(
            AppTheme.contrastScheme(Brightness.light),
          ),
          highContrastDarkTheme: AppTheme.dark(
            AppTheme.contrastScheme(Brightness.dark),
          ),
          builder: (context, child) {
            final media = MediaQuery.of(context);
            return MediaQuery(
              data: media.copyWith(
                textScaler: AppTextScaler(
                  media.textScaler,
                  accessibility.textScale,
                ),
              ),
              child: child!,
            );
          },
          home: const AppShell(),
        );
      },
    );
  }
}

/// Swaps between a bottom bar and a rail at 600 dp.
///
/// Done with a `LayoutBuilder` rather than an adaptive-navigation package: it is
/// a single breakpoint and a dependency would be more code than the check.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;

  /// Restores what was remembered from last time.
  ///
  /// Done here rather than in `main` so it happens once the providers exist,
  /// and not at all in a widget test that never pumps the shell.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(settingsProvider.notifier).restore());
      unawaited(ref.read(themeModeProvider.notifier).restore());
      unawaited(ref.read(accessibilityProvider.notifier).restore());
      unawaited(ref.read(hiddenBlockKeysProvider.notifier).restore());
      unawaited(ref.read(soloBlockKeyProvider.notifier).restore());
      unawaited(ref.read(exportDirectoryProvider.notifier).restore());
    });
    WindowControls.onCloseError = (message) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    };
  }

  @override
  void dispose() {
    WindowControls.onCloseError = null;
    super.dispose();
  }

  static const _destinations = <NavigationDestination>[
    NavigationDestination(
      icon: Icon(Icons.auto_awesome_outlined),
      selectedIcon: Icon(Icons.auto_awesome),
      label: '生成',
    ),
    NavigationDestination(
      icon: Icon(Icons.grid_on_outlined),
      selectedIcon: Icon(Icons.grid_on),
      label: '图纸',
    ),
    NavigationDestination(
      icon: Icon(Icons.inventory_2_outlined),
      selectedIcon: Icon(Icons.inventory_2),
      label: '材料',
    ),
    NavigationDestination(
      icon: Icon(Icons.ios_share_outlined),
      selectedIcon: Icon(Icons.ios_share),
      label: '导出',
    ),
    NavigationDestination(
      icon: Icon(Icons.tune_outlined),
      selectedIcon: Icon(Icons.tune),
      label: '设置',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: desktop,
      builder: (context, _) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (desktop.floating) unawaited(desktop.toggleFloating());
          },
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final floating = desktop.floating;
            final wide =
                constraints.maxWidth >= 600 &&
                constraints.maxHeight >= 480 &&
                MediaQuery.textScalerOf(context).scale(14) <= 21;

            final body = IndexedStack(
              index: floating ? 1 : _index,
              children: [
                const HomePage(),
                BlueprintPage(compact: floating),
                const MaterialsPage(),
                const ExportPage(),
                const SettingsPage(),
              ],
            );

            return Scaffold(
              appBar: WindowControls.enabled
                  ? AppTitleBar(floating: floating)
                  : null,
              body: Row(
                children: [
                  if (wide && !floating) ...[
                    NavigationRail(
                      selectedIndex: _index,
                      onDestinationSelected: (i) => setState(() => _index = i),
                      labelType: NavigationRailLabelType.all,
                      destinations: [
                        for (final destination in _destinations)
                          NavigationRailDestination(
                            icon: destination.icon,
                            selectedIcon: destination.selectedIcon,
                            label: Text(destination.label),
                          ),
                      ],
                    ),
                    VerticalDivider(
                      width: 1,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ],
                  Expanded(key: const ValueKey('pages'), child: body),
                ],
              ),
              bottomNavigationBar: wide || floating
                  ? null
                  : NavigationBar(
                      selectedIndex: _index,
                      onDestinationSelected: (i) => setState(() => _index = i),
                      destinations: _destinations,
                    ),
            );
          },
        ),
      ),
    );
  }
}
