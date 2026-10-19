import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapart_core/mapart_core.dart';
import 'package:material_ui/material_ui.dart';

import '../widgets/adaptive_segments.dart';

import '../state/project.dart';

/// The shopping list, and the place blocks get hidden.
///
/// Sorted by how many of each the picture uses, because that is the order you
/// want to read a shopping list in, and because the top few lines are almost
/// always most of the build. Tapping a line hides that block in the preview;
/// holding it shows that block *alone*.
class MaterialsPage extends ConsumerWidget {
  const MaterialsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(resultProvider);
    final plan = result.value?.plan;

    return Scaffold(
      body: plan == null
          ? _EmptyState(
              loading: result.isLoading,
              message: result.hasError ? '${result.error}' : null,
            )
          : _MaterialList(plan: plan),
    );
  }
}

class _MaterialList extends ConsumerStatefulWidget {
  const _MaterialList({required this.plan});

  final MapPlan plan;

  @override
  ConsumerState<_MaterialList> createState() => _MaterialListState();
}

class _MaterialListState extends ConsumerState<_MaterialList> {
  String _query = '';
  String _scope = 'picture';
  MapPlan get plan => widget.plan;

  @override
  Widget build(BuildContext context) {
    final hidden = ref.watch(hiddenBlockKeysProvider);
    final solo = ref.watch(soloBlockKeyProvider);
    final notifier = ref.read(hiddenBlockKeysProvider.notifier);
    final summary = BuildSummary.fromPlan(
      plan,
      shape: _scope == 'solid' ? ExportShape.solid : ExportShape.surface,
      includeReferenceRow: _scope != 'picture' && plan.requiresReferenceRow,
    );
    final totals = summary.totals;
    final matching = <int>[
      for (var i = 0; i < plan.blocks.length; i++)
        if ('${plan.blocks[i].nameZh} ${plan.blocks[i].nameEn} ${plan.blocks[i].blockId}'
            .toLowerCase()
            .contains(_query.toLowerCase()))
          i,
    ];
    final scheme = Theme.of(context).colorScheme;

    return CustomScrollView(
      slivers: [
        const SliverAppBar.large(title: Text('材料')),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索方块名称或 ID',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
                const SizedBox(height: 12),
                AdaptiveSegments<String>(
                  segments: const [
                    ButtonSegment(value: 'picture', label: Text('画面用量')),
                    ButtonSegment(value: 'surface', label: Text('表层构建')),
                    ButtonSegment(value: 'solid', label: Text('实心构建')),
                  ],
                  selected: {_scope},
                  onSelectionChanged: (value) =>
                      setState(() => _scope = value.first),
                ),
                const SizedBox(height: 8),
                Text(
                  _scope == 'picture'
                      ? '仅统计画面，不含参照行和填充。'
                      : plan.requiresReferenceRow
                      ? '构建用量包含参照行，与对应导出选项一致。'
                      : '单层方块像素画，无需参照行。',
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _Summary(
            totals: totals,
            hidden: hidden.length,
            solo: solo,
            plan: plan,
            onShowAll: notifier.showAll,
            onHideAll: () =>
                notifier.hideAll([for (final block in plan.blocks) block.key]),
            onClearSolo: () =>
                ref.read(soloBlockKeyProvider.notifier).set(null),
          ),
        ),
        SliverList.builder(
          itemCount: matching.length,
          itemBuilder: (context, row) {
            final index = matching[row];
            return _MaterialTile(
              line: MaterialLine(
                block: plan.blocks[index],
                count: summary.counts[index],
              ),
              hidden: hidden.contains(plan.blocks[index].key),
              solo: solo == plan.blocks[index].key,
              onTap: () => notifier.toggle(plan.blocks[index].key),
              onLongPress: () => ref
                  .read(soloBlockKeyProvider.notifier)
                  .toggle(plan.blocks[index].key),
            );
          },
        ),
        if (matching.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('没有匹配的方块，请尝试其他名称或 ID。'),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            child: Text(
              '点一下隐藏这种方块(预览、图纸里画成棋盘格),长按只看这一种。'
              '隐藏只影响显示,不影响材料数量,也不影响导出的投影。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.totals,
    required this.hidden,
    required this.solo,
    required this.plan,
    required this.onShowAll,
    required this.onHideAll,
    required this.onClearSolo,
  });

  final MaterialTotals totals;
  final int hidden;
  final String? solo;
  final MapPlan plan;
  final VoidCallback onShowAll;
  final VoidCallback onHideAll;
  final VoidCallback onClearSolo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card.filled(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Fact(label: '方块总数', value: '${totals.blocks} 个'),
                  _Fact(
                    label: '折合',
                    value:
                        '${totals.stacks} 组 + ${totals.rest} 个 '
                        '(${totals.stackSlots} 格)',
                  ),
                  _Fact(label: '种类', value: '${totals.kinds} 种'),
                  _Fact(
                    label: '高度',
                    value:
                        'Y ${plan.minHeight}..${plan.maxHeight} '
                        '(${plan.blockHeightSpan} 层)',
                  ),
                  _Fact(
                    label: '参照行',
                    value: !plan.requiresReferenceRow
                        ? '不需要（方块像素画）'
                        : 'Y ${plan.referenceRowHeight}'
                              ' · ${plan.width} 个方块,在图外最北一行',
                  ),
                ],
              ),
            ),
          ),
          if (solo != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: InputChip(
                avatar: const Icon(Icons.filter_alt, size: 18),
                label: Text('只看:${_labelFor(plan, solo!)}'),
                onDeleted: onClearSolo,
                deleteIcon: const Icon(Icons.close, size: 18),
              ),
            ),
          ],
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                onPressed: hidden == 0 ? null : onShowAll,
                icon: const Icon(Icons.visibility, size: 18),
                label: const Text('全部显示'),
              ),
              TextButton.icon(
                onPressed: onHideAll,
                icon: const Icon(Icons.visibility_off, size: 18),
                label: const Text('全部隐藏'),
              ),
              if (hidden > 0)
                Text(
                  '已隐藏 $hidden 种',
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _labelFor(MapPlan plan, String key) {
    final index = plan.indexOfKey(key);
    return index < 0 ? key : plan.blocks[index].nameZh;
  }
}

class _MaterialTile extends StatelessWidget {
  const _MaterialTile({
    required this.line,
    required this.hidden,
    required this.solo,
    required this.onTap,
    required this.onLongPress,
  });

  final MaterialLine line;
  final bool hidden;
  final bool solo;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final block = line.block;
    final stacked =
        MediaQuery.sizeOf(context).width < 600 ||
        MediaQuery.textScalerOf(context).scale(14) > 18;
    final count = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: stacked
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.end,
      children: [
        Text('${line.count}', style: Theme.of(context).textTheme.titleMedium),
        Text(
          '${line.stacks} 组 + ${line.rest}',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
    return ListTile(
      dense: true,
      onTap: onTap,
      onLongPress: onLongPress,
      leading: Opacity(
        opacity: hidden ? 0.35 : 1,
        child: _ShadeStrip(block: block),
      ),
      title: Text(
        block.nameZh,
        style: TextStyle(
          decoration: hidden ? TextDecoration.lineThrough : null,
          color: hidden ? scheme.onSurfaceVariant : null,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hidden || solo) Text(hidden ? '已隐藏' : '只看此方块'),
          Text(
            '${block.blockId} · ${block.nameEn}',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (stacked) count,
        ],
      ),
      trailing: stacked ? null : count,
      selected: solo,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.4),
    );
  }
}

/// The three shades of one block, side by side, which is what the map will
/// actually show.
class _ShadeStrip extends StatelessWidget {
  const _ShadeStrip({required this.block});

  final PlanBlock block;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 22,
    height: 22,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(4),
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

/// One labelled number in the summary card.
class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
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
              Icon(
                Icons.inventory_2_outlined,
                size: 48,
                color: scheme.onSurfaceVariant,
              ),
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
