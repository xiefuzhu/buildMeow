import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapart_core/mapart_core.dart';
import 'package:material_ui/material_ui.dart';

import '../state/project.dart';
import '../widgets/blueprint_viewer.dart';

/// The blueprint: the picture as a grid you can read, one map at a time or all
/// of it at once.
///
/// The information a builder needs and a preview cannot give: which block is
/// where, how high it sits, and which step it makes against the block to its
/// north. Everything shown is read from the same `MapPlan` the schematic
/// writers use.
class BlueprintPage extends ConsumerStatefulWidget {
  const BlueprintPage({super.key, this.compact = false});
  final bool compact;

  @override
  ConsumerState<BlueprintPage> createState() => _BlueprintPageState();
}

class _BlueprintPageState extends ConsumerState<BlueprintPage> {
  final _viewerKey = GlobalKey<BlueprintViewerState>();

  /// Whether to look at one map at a time or at the whole picture.
  bool _single = true;

  /// Which tile, as a row and a column.
  int _tile = 0;

  BlueprintCell? _picked;
  MapPlan? _lastPlan;

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(resultProvider);
    final plan = result.value?.plan;
    if (!identical(plan, _lastPlan)) {
      _picked = null;
      _lastPlan = plan;
    }
    if (plan != null) _tile = _tile.clamp(0, plan.mapCount - 1);

    return Scaffold(
      appBar: widget.compact ? null : AppBar(title: const Text('图纸')),
      body: plan == null
          ? _EmptyState(
              loading: result.isLoading,
              message: result.hasError ? '${result.error}' : null,
            )
          : LayoutBuilder(
              builder: (context, constraints) => Column(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * 0.35,
                    ),
                    child: SingleChildScrollView(
                      child: _Toolbar(
                        compact: widget.compact,
                        plan: plan,
                        single: _single,
                        tile: _tile,
                        onSingleChanged: (value) => setState(() {
                          _single = value;
                          _picked = null;
                        }),
                        onTileChanged: (value) => setState(() {
                          _tile = value;
                          _picked = null;
                        }),
                        onReset: () => _viewerKey.currentState?.reset(),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ColoredBox(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerLowest,
                      child: BlueprintViewer(
                        key: _viewerKey,
                        plan: plan,
                        hidden: ref.watch(hiddenPlanIndicesProvider),
                        tile: _single ? _tileOf(plan, _tile) : null,
                        onPick: (cell) => setState(() => _picked = cell),
                      ),
                    ),
                  ),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * 0.35,
                    ),
                    child: SingleChildScrollView(
                      child: _Readout(
                        plan: plan,
                        cell: _picked,
                        compact: widget.compact,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  static ({int x, int y}) _tileOf(MapPlan plan, int index) =>
      (x: index % plan.mapsX, y: index ~/ plan.mapsX);
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.compact,
    required this.plan,
    required this.single,
    required this.tile,
    required this.onSingleChanged,
    required this.onTileChanged,
    required this.onReset,
  });

  final MapPlan plan;
  final bool compact;
  final bool single;
  final int tile;
  final ValueChanged<bool> onSingleChanged;
  final ValueChanged<int> onTileChanged;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final tileX = tile % plan.mapsX;
    final tileY = tile ~/ plan.mapsX;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<bool>(
            style: SegmentedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
            segments: const [
              ButtonSegment(value: true, label: Text('单张')),
              ButtonSegment(value: false, label: Text('整幅')),
            ],
            selected: {single},
            onSelectionChanged: (value) => onSingleChanged(value.first),
            showSelectedIcon: false,
          ),
          if (single && plan.mapCount > 1)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IconButton(
                  onPressed: tile > 0 ? () => onTileChanged(tile - 1) : null,
                  icon: const Icon(Icons.chevron_left),
                  tooltip: '上一张',
                ),
                Text(
                  compact
                      ? '${tile + 1}/${plan.mapCount} · ${tileY + 1}行${tileX + 1}列'
                      : '第 ${tile + 1}/${plan.mapCount} 张 · 第 ${tileY + 1} 行 '
                            '第 ${tileX + 1} 列',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                IconButton(
                  onPressed: tile < plan.mapCount - 1
                      ? () => onTileChanged(tile + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                  tooltip: '下一张',
                ),
              ],
            )
          else if (!compact)
            Text(
              '${plan.width} x ${plan.height} 格 · '
              '每 16 格一条区块线',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          IconButton(
            onPressed: onReset,
            icon: const Icon(Icons.center_focus_strong),
            tooltip: '复位视图',
          ),
        ],
      ),
    );
  }
}

/// What the tapped cell is.
///
/// Shown as a bar rather than a tooltip or a dialog: you tap cell after cell
/// while building, and anything that has to be dismissed each time is worse
/// than useless.
class _Readout extends StatelessWidget {
  const _Readout({
    required this.plan,
    required this.cell,
    required this.compact,
  });

  final MapPlan plan;
  final BlueprintCell? cell;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final at = cell;

    return Material(
      color: scheme.surfaceContainerHigh,
      child: Semantics(
        liveRegion: true,
        child: at == null
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  compact ? '点击格子或用方向键查看' : '点一下格子,看这一格是什么方块、要多高',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _Swatch(block: plan.blockAt(at.x, at.y)),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          plan.blockAt(at.x, at.y).nameZh,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          plan.blockAt(at.x, at.y).blockId,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                    _Fact(label: '位置', value: 'x ${at.x}  z ${at.y}'),
                    _Fact(label: '高度', value: 'Y ${plan.heightAt(at.x, at.y)}'),
                    _Fact(
                      label: '比北边',
                      value: switch (plan.relativeHeightAt(at.x, at.y)) {
                        > 0 => '高 1 格 · 最亮',
                        < 0 => '低 1 格 · 最暗',
                        _ => '一样高 · 中等',
                      },
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.block});

  final PlanBlock block;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 32,
    height: 32,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Row(
        children: [
          for (final tier in ShadeTier.staircase)
            Expanded(child: ColoredBox(color: _color(block.tone(tier)))),
        ],
      ),
    ),
  );

  static Color _color(Rgb rgb) => Color.fromARGB(255, rgb.r, rgb.g, rgb.b);
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          Text(value, style: Theme.of(context).textTheme.labelLarge),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.loading, this.message});

  final bool loading;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const CircularProgressIndicator()
            else
              Icon(Icons.grid_on_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: 16),
            Text(
              loading ? '正在算…' : message ?? '还没有生成过,先去「生成」页选一张图片',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
