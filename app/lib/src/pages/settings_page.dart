import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../widgets/accessible_slider.dart';

import '../widgets/adaptive_segments.dart';

import '../data/preferences.dart';
import '../widgets/app_logo.dart';
import '../state/accessibility.dart';
import '../window/desktop_integration.dart';

/// Light, dark, or follow the platform.
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  int _revision = 0;
  @override
  ThemeMode build() => ThemeMode.system;

  Future<void> restore() async {
    final revision = _revision;
    final stored = await Preferences.loadThemeMode();
    final mode = ThemeMode.values.where((m) => m.name == stored).firstOrNull;
    if (ref.mounted && revision == _revision && mode != null) state = mode;
  }

  void set(ThemeMode mode) {
    _revision++;
    state = mode;
    unawaited(Preferences.saveThemeMode(mode.name));
  }
}

/// The settings screen.
///
/// Uses a large app bar because this is the one page that actually scrolls; the
/// preview page needs its height for the picture.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final accessibility = ref.watch(accessibilityProvider);
    final scheme = Theme.of(context).colorScheme;

    return CustomScrollView(
      slivers: [
        const SliverAppBar.large(title: Text('设置')),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          sliver: SliverList.list(
            children: [
              Text(
                '外观',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              AdaptiveSegments<ThemeMode>(
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('跟随系统'),
                    icon: Icon(Icons.brightness_auto),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('浅色'),
                    icon: Icon(Icons.light_mode),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('深色'),
                    icon: Icon(Icons.dark_mode),
                  ),
                ],
                selected: {mode},
                onSelectionChanged: (s) =>
                    ref.read(themeModeProvider.notifier).set(s.first),
              ),
              const SizedBox(height: 8),
              Text(
                'Android 12 及以上会跟随壁纸取色,Windows 上跟随系统强调色;'
                '取不到时用内置的种子色生成。',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 28),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('高对比度'),
                subtitle: const Text('加强文字、按钮和边界对比；系统高对比度也会自动生效。'),
                value: accessibility.highContrast,
                onChanged: (value) => ref
                    .read(accessibilityProvider.notifier)
                    .set(highContrast: value),
              ),
              Text(
                '字体大小：${(accessibility.textScale * 100).round()}%（叠加系统字体设置）',
              ),
              AccessibleSlider(
                value: accessibility.textScale,
                min: 1,
                max: 2,
                divisions: 4,
                label: '${(accessibility.textScale * 100).round()}%',
                semanticFormatterCallback: (v) => '${(v * 100).round()}%',
                onChanged: (value) => ref
                    .read(accessibilityProvider.notifier)
                    .set(textScale: value),
              ),
              TextButton(
                onPressed: () => ref
                    .read(accessibilityProvider.notifier)
                    .set(textScale: 1, highContrast: false),
                child: const Text('恢复系统外观与字体'),
              ),
              if (desktop.available) const _DesktopSettings(),
              const SizedBox(height: 28),
              ValueListenableBuilder<String?>(
                valueListenable: Preferences.error,
                builder: (context, error, _) => error != null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '设置保存失败：$error',
                            style: TextStyle(color: scheme.error),
                          ),
                          TextButton(
                            onPressed: Preferences.retry,
                            child: const Text('重试保存'),
                          ),
                        ],
                      )
                    : ValueListenableBuilder<bool>(
                        valueListenable: Preferences.saving,
                        builder: (context, saving, _) =>
                            Text(saving ? '正在保存设置…' : '设置、外观、导出选项与位置会自动保存。'),
                      ),
              ),
              const SizedBox(height: 28),
              Text(
                '关于',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Card.filled(
                child: ListTile(
                  leading: AppLogo(size: 40),
                  title: Text('建喵!'),
                  subtitle: Text('测试版 1.0.0-beta.1 · 离线方块像素画与地图画生成器'),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                '未验证',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: scheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '当前数据目标为 Minecraft Java 26.1.2。导出的投影与游戏中的地图颜色尚未在游戏内实测；'
                '纹理预览按标准光照近似，不能代替实际场景截图。Android 编译兼容与真机交互验收是不同检查。',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
              ),
              const SizedBox(height: 28),
              Text(
                '色表来源',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'MapartCraft (GPL-3.0) 的 coloursJSON.json,'
                'commit 0f24df5d。本应用整体按 GPL-3.0 发布。',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DesktopSettings extends StatelessWidget {
  const _DesktopSettings();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: desktop,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        Text('Windows 桌面', style: Theme.of(context).textTheme.titleMedium),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('全局快捷键'),
          subtitle: Text(
            '${desktop.shortcutPrefix}+M 显示 / 隐藏；${desktop.shortcutPrefix}+F 切换悬浮图纸。',
          ),
          value: desktop.hotkeysEnabled,
          onChanged: desktop.busy ? null : (v) => desktop.configure(hotkeys: v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('使用备用组合键（增加 Shift）'),
          value: desktop.extraShift,
          onChanged: desktop.busy ? null : (v) => desktop.configure(shift: v),
        ),
        Text(
          '托盘：${desktop.trayReady ? "就绪" : "不可用"} · 显示快捷键：${desktop.showHotkeyReady ? "已注册" : "未注册"} · 悬浮快捷键：${desktop.floatHotkeyReady ? "已注册" : "未注册"}',
        ),
        if (desktop.error != null)
          Semantics(
            liveRegion: true,
            child: Text(
              desktop.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: desktop.busy ? null : desktop.configure,
              child: const Text('重试注册'),
            ),
            FilledButton.tonalIcon(
              onPressed: desktop.busy ? null : desktop.toggleFloating,
              icon: const Icon(Icons.picture_in_picture_alt),
              label: const Text('打开悬浮图纸'),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('关闭按钮隐藏到托盘'),
          subtitle: const Text('默认关闭会退出。开启后从托盘菜单选择「退出」；退出前仍会等待设置保存。'),
          value: desktop.closeToTray,
          onChanged: desktop.busy
              ? null
              : (v) => desktop.configure(minimizeOnClose: v),
        ),
        const Text('悬浮窗口会置顶，支持拖动、缩放和读取图纸；Esc 返回普通窗口。游戏使用无边框窗口模式时更便于对照。'),
      ],
    ),
  );
}
