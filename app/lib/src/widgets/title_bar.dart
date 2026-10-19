import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../window/window_controls.dart';
import '../window/desktop_integration.dart';
import 'app_logo.dart';

/// Height of the bar. Also the height the layout below it has to account for.
const double kTitleBarHeight = 40;

/// The app's own title bar, replacing the Windows one.
///
/// The window is created with `TitleBarStyle.hidden`, which removes the caption
/// but keeps the resize frame, so resizing still works. This bar supplies what
/// was removed.
///
/// Windows dragging samples the native screen cursor through a small method
/// channel. Flutter's global pointer coordinates belong to the client area and
/// change when that window moves; using them as screen coordinates causes jitter.
/// The native implementation avoids the synchronous modal move loop previously
/// observed to crash this Flutter build. Aero Snap remains unavailable.
///
/// It is not placed in `MaterialApp.builder`: that runs above the Navigator, so
/// a bar put there is outside the `Overlay` that `Tooltip` and `InkWell` look
/// for.
class AppTitleBar extends StatelessWidget implements PreferredSizeWidget {
  const AppTitleBar({super.key, this.floating = false});
  final bool floating;

  @override
  Size get preferredSize => const Size.fromHeight(kTitleBarHeight);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: kTitleBarHeight,
      titleSpacing: 12,
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      // The label is the AppBar's own `title`, not part of `flexibleSpace`,
      // because the AppBar centres its title in the toolbar for us. Putting the
      // text in `flexibleSpace` — which fills the whole bar — left it sitting
      // against the top edge.
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppLogo(),
          const SizedBox(width: 8),
          Text(
            floating ? '悬浮图纸' : '建喵!',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (!floating &&
              MediaQuery.sizeOf(context).width >= 850 &&
              MediaQuery.textScalerOf(context).scale(14) < 21) ...[
            const SizedBox(width: 8),
            Text(
              'Minecraft 地图画生成器',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
      // The drag area. It sits behind the toolbar and covers the whole bar, so
      // the empty space to the right of the label drags too. It stays behind
      // the action buttons, which absorb their own taps.
      flexibleSpace: _DragArea(allowMaximize: !floating),
      actions: [
        if (desktop.available)
          IconButton(
            onPressed: desktop.busy ? null : desktop.toggleFloating,
            icon: Icon(
              floating ? Icons.open_in_full : Icons.picture_in_picture_alt,
              size: 18,
            ),
            tooltip: floating ? '退出悬浮（Esc）' : '悬浮图纸',
          ),
        if (desktop.available && desktop.trayReady && !floating)
          IconButton(
            onPressed: desktop.hide,
            icon: const Icon(Icons.system_update_alt, size: 18),
            tooltip: '隐藏到托盘',
          ),
        IconButton(
          onPressed: WindowControls.minimize,
          icon: const Icon(Icons.horizontal_rule, size: 18),
          tooltip: '最小化',
          visualDensity: VisualDensity.compact,
        ),
        if (!floating)
          IconButton(
            onPressed: WindowControls.toggleMaximize,
            icon: const Icon(Icons.crop_square, size: 16),
            tooltip: '最大化 / 还原',
            visualDensity: VisualDensity.compact,
          ),
        IconButton(
          onPressed: desktop.requestClose,
          icon: const Icon(Icons.close, size: 18),
          tooltip: '关闭',
          visualDensity: VisualDensity.compact,
        ),
        const SizedBox(width: 6),
      ],
    );
  }
}

/// Sends coalesced move requests; the runner reads the latest screen cursor.
class _DragArea extends StatefulWidget {
  const _DragArea({required this.allowMaximize});
  final bool allowMaximize;

  @override
  State<_DragArea> createState() => _DragAreaState();
}

class _DragAreaState extends State<_DragArea> {
  bool _dragging = false;
  bool _moving = false;
  bool _pending = false;
  int _revision = 0;

  Future<void> _onPanStart(DragStartDetails details) async {
    final revision = ++_revision;
    _pending = false;
    final ready = await WindowControls.beginDrag();
    if (!mounted || revision != _revision) return;
    _dragging = ready;
    if (_dragging && _pending && !_moving) unawaited(_move());
  }

  void _onPanUpdate(DragUpdateDetails details) {
    _pending = true;
    if (_dragging && !_moving) unawaited(_move());
  }

  Future<void> _move() async {
    _moving = true;
    try {
      while (mounted && _dragging && _pending) {
        _pending = false;
        await WindowControls.updateDrag();
      }
    } finally {
      _moving = false;
    }
  }

  void _onPanEnd() {
    ++_revision;
    _dragging = false;
    _pending = false;
    unawaited(WindowControls.endDrag());
  }

  @override
  void dispose() {
    _onPanEnd();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: widget.allowMaximize ? WindowControls.toggleMaximize : null,
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: (_) => _onPanEnd(),
      onPanCancel: _onPanEnd,
      child: const SizedBox.expand(),
    );
  }
}
