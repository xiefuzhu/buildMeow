import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapart_core/mapart_core.dart';
import 'package:material_ui/material_ui.dart';

import '../data/pipeline.dart';
import '../data/rerender.dart';
import '../state/project.dart';
import '../state/display.dart';
import '../widgets/map_viewer.dart';
import '../widgets/params_panel.dart';

/// The main screen: the picture, with the controls under it.
///
/// The layout switches at 600 dp. Narrow, the preview fills the screen and the
/// controls live in a draggable sheet so the picture keeps the space. Wide, the
/// controls sit in a column beside the preview and can be collapsed.
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final _viewerKey = GlobalKey<MapViewerState>();

  Timer? _hiddenRerender;
  int _displayRevision = 0;
  PipelineResult? _decodedSource;
  PipelineResult? _paintedResult;
  PipelineResult? _targetResult;
  String? _previewError;

  ui.Image? _rendered;
  ui.Image? _target;
  bool _showingTarget = false;
  bool _panelCollapsed = false;

  @override
  void dispose() {
    _hiddenRerender?.cancel();
    _rendered?.dispose();
    _target?.dispose();
    super.dispose();
  }

  void _scheduleHiddenRerender() {
    _displayRevision++;
    _hiddenRerender?.cancel();
    _hiddenRerender = Timer(const Duration(milliseconds: 120), () {
      final data = ref.read(resultProvider).value;
      if (mounted && data != null) unawaited(_loadPreview(data, target: false));
    });
  }

  Future<void> _generate() => ref.read(resultProvider.notifier).generate();

  Future<void> _loadPreview(PipelineResult data, {bool target = true}) async {
    final revision = ++_displayRevision;
    ui.Image? rendered;
    ui.Image? original;
    try {
      final hidden = Set<int>.from(ref.read(hiddenPlanIndicesProvider));
      var pixels = data.preview;
      if (hidden.isNotEmpty) {
        final textures = await ref.read(textureAtlasProvider.future);
        if (!mounted || revision != _displayRevision) return;
        pixels = await ref.read(previewRasterizerProvider)(
          PreviewRequest(
            plan: data.plan,
            hiddenBlocks: hidden,
            textureAtlas: data.textured ? textures.png : null,
            textureIndex: data.textured ? textures.index : const {},
            textureCell: data.textured ? textures.cell : 1,
          ),
        );
      }
      if (!mounted || revision != _displayRevision) return;
      final decoder = ref.read(previewDecoderProvider);
      rendered = await decoder(pixels);
      if (target || !identical(_targetResult, data)) {
        original = await decoder(data.target);
      }
      if (!mounted ||
          revision != _displayRevision ||
          !identical(data, ref.read(resultProvider).value)) {
        return;
      }
      setState(() {
        _rendered?.dispose();
        _rendered = rendered;
        _paintedResult = data;
        _previewError = null;
        if (original != null) {
          _target?.dispose();
          _target = original;
          _targetResult = data;
        }
      });
      rendered = null;
      original = null;
    } on Object catch (error) {
      if (mounted && revision == _displayRevision) {
        setState(() => _previewError = '预览失败：$error。请重新生成。');
      }
    } finally {
      rendered?.dispose();
      original?.dispose();
    }
  }

  void _clearImages() {
    _displayRevision++;
    _decodedSource = null;
    _paintedResult = null;
    _targetResult = null;
    _previewError = null;
    setState(() {
      _rendered?.dispose();
      _target?.dispose();
      _rendered = null;
      _target = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(settingsProvider, (previous, next) {
      if (previous != null && next.affectsRender(previous)) _displayRevision++;
    });

    // A different picture invalidates everything on screen. A settings change
    // does not: the solve that follows replaces it in place, which is why the
    // old render is deliberately kept while the new one is computed instead of
    // blanking the viewer on every slider tick.
    ref.listen(sourceImageProvider, (previous, next) {
      if (!identical(previous, next)) {
        _clearImages();
      }
    });

    ref.listen(resultProvider, (previous, next) {
      final data = next.value;
      if (data != null && !identical(previous?.value, data)) {
        _decodedSource = data;
        unawaited(_loadPreview(data));
      }
    });
    final initial = ref.read(resultProvider).value;
    if (initial != null && !identical(initial, _decodedSource)) {
      _decodedSource = initial;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(initial, ref.read(resultProvider).value)) {
          unawaited(_loadPreview(initial));
        }
      });
    }

    // Hiding a block redraws the picture without touching the solve.
    ref.listen(hiddenPlanIndicesProvider, (previous, next) {
      if (previous != null && setEquals(previous, next)) return;
      _scheduleHiddenRerender();
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        final panel = ParamsPanel(onGenerate: _generate);
        final wide = constraints.maxWidth >= 1000;
        return Scaffold(
          endDrawer: wide
              ? null
              : Drawer(
                  width: 340,
                  child: SafeArea(
                    child: Column(
                      children: [
                        const ListTile(
                          title: Text('生成参数'),
                          subtitle: Text('调整后自动更新预览'),
                        ),
                        Expanded(child: panel),
                      ],
                    ),
                  ),
                ),
          body: wide
              ? _WideLayout(
                  viewer: _viewer(),
                  panel: panel,
                  collapsed: _panelCollapsed,
                  onToggleCollapsed: () =>
                      setState(() => _panelCollapsed = !_panelCollapsed),
                )
              : Column(
                  children: [
                    Builder(
                      builder: (context) => ListTile(
                        dense: true,
                        title: const Text('生成'),
                        subtitle: Text(
                          ref.watch(settingsProvider).cropMode ==
                                  CropMode.contain
                              ? '等比适应 · 完整保留图片'
                              : '等比裁剪 · 超出画布的内容会裁去',
                        ),
                        trailing: FilledButton.tonalIcon(
                          onPressed: () => Scaffold.of(context).openEndDrawer(),
                          icon: const Icon(Icons.tune),
                          label: const Text('参数'),
                        ),
                      ),
                    ),
                    Expanded(child: _viewer()),
                  ],
                ),
        );
      },
    );
  }

  Widget _viewer() {
    final image = _showingTarget ? _target : _rendered;
    final result = ref.watch(resultProvider);
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        fit: StackFit.expand,
        children: [
          MapViewer(
            key: _viewerKey,
            image: image,
            mapPixel: _cellsPerMapPixel(image, _paintedResult),
            showGrid: false,
            emptyLabel: _rendered == null ? '选一张图片,就会自动生成预览' : '还没有生成预览',
          ),
          if (result.isLoading ||
              (_rendered != null && result.value == null && !result.hasError))
            Positioned(
              left: 8,
              bottom: 8,
              child: _BusyChip(label: result.isLoading ? '生成中…' : '等待更新…'),
            ),
          if (result.hasError || _previewError != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Card.filled(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  title: Text(_previewError ?? '生成失败：${result.error}'),
                  subtitle: const Text('检查图片或参数后重试。'),
                  trailing: TextButton(
                    onPressed: _generate,
                    child: const Text('重试'),
                  ),
                ),
              ),
            ),
          if (_rendered != null)
            Positioned(
              top: 8,
              right: 8,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: (constraints.maxHeight - 16).clamp(
                    0,
                    double.infinity,
                  ),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _ViewToggle(
                        showingTarget: _showingTarget,
                        onChanged: (v) => setState(() => _showingTarget = v),
                      ),
                      const SizedBox(height: 8),
                      _RotateTools(
                        onQuarterTurn: (q) =>
                            _viewerKey.currentState?.rotateByQuarterTurns(q),
                        onReset: () => _viewerKey.currentState?.reset(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Texels along one map cell in [image].
  ///
  /// The preview paints each block as its face texture, so that bitmap is a
  /// whole number of times the map. The resampled source is already one pixel
  /// per cell, and the ratio comes out as 1. The badge uses this so it shows
  /// the same `640x640` as the size panel.
  int _cellsPerMapPixel(ui.Image? image, PipelineResult? data) {
    if (image == null || data == null || data.width == 0 || data.height == 0) {
      return 1;
    }
    final cell = image.width ~/ data.width;
    if (cell < 1) return 1;
    if (image.width != data.width * cell ||
        image.height != data.height * cell) {
      return 1;
    }
    return cell;
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout({
    required this.viewer,
    required this.panel,
    required this.collapsed,
    required this.onToggleCollapsed,
  });

  final Widget viewer;
  final Widget panel;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(child: viewer),
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          width: collapsed ? 56 : 320,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            border: Border(left: BorderSide(color: scheme.outlineVariant)),
          ),
          child: collapsed
              ? Center(
                  child: IconButton(
                    onPressed: onToggleCollapsed,
                    icon: const Icon(Icons.chevron_left),
                    tooltip: '展开参数',
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                      child: Row(
                        children: [
                          Text(
                            '参数',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Spacer(),
                          IconButton(
                            onPressed: onToggleCollapsed,
                            icon: const Icon(Icons.chevron_right),
                            tooltip: '收起参数',
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Material(
                        type: MaterialType.transparency,
                        child: panel,
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Shown while a solve is in flight, so the picture on screen is not mistaken
/// for the current settings.
class _BusyChip extends StatelessWidget {
  const _BusyChip({this.label = '生成中…'});
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Switches the preview between the rendered map and the resampled source.
///
/// Worth having next to the picture rather than buried in the panel: judging a
/// palette means flipping between the two.
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.showingTarget, required this.onChanged});

  final bool showingTarget;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.9),
      ),
      segments: const [
        ButtonSegment(value: false, label: Text('预览')),
        ButtonSegment(value: true, label: Text('构图原图')),
      ],
      selected: {showingTarget},
      onSelectionChanged: (s) => onChanged(s.first),
      showSelectedIcon: false,
    );
  }
}

class _RotateTools extends StatelessWidget {
  const _RotateTools({required this.onQuarterTurn, required this.onReset});

  final ValueChanged<int> onQuarterTurn;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ToolButton(
          icon: Icons.rotate_left,
          tooltip: '逆时针 90°',
          onPressed: () => onQuarterTurn(-1),
        ),
        const SizedBox(height: 6),
        _ToolButton(
          icon: Icons.rotate_right,
          tooltip: '顺时针 90°',
          onPressed: () => onQuarterTurn(1),
        ),
        const SizedBox(height: 6),
        _ToolButton(
          icon: Icons.center_focus_strong,
          tooltip: '复位(也可以双击图片)',
          onPressed: onReset,
        ),
      ],
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest
          .withValues(alpha: 0.9),
      shape: const CircleBorder(),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
