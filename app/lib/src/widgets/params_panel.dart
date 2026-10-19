import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapart_core/mapart_core.dart';
import 'package:material_ui/material_ui.dart';

import 'accessible_slider.dart';

import 'adaptive_segments.dart';

import '../state/project.dart';

/// The controls under the preview.
///
/// Everything here writes straight into [settingsProvider], and the settings
/// notifier clears the last result whenever a change would alter the picture,
/// so the generate button is the only thing that has to be pressed again.
class ParamsPanel extends ConsumerWidget {
  const ParamsPanel({super.key, required this.onGenerate});

  final Future<void> Function() onGenerate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final source = ref.watch(sourceImageProvider);
    final versions = ref.watch(versionTableProvider).value;
    final result = ref.watch(resultProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _SourcePicker(settings: settings, source: source),
        const SizedBox(height: 16),
        _Section(
          title: '尺寸',
          subtitle:
              '${settings.mapCount} 张地图 · '
              '${settings.pixelWidth}x${settings.pixelHeight} 像素',
          child: Column(
            children: [
              _Stepper(
                label: '横向张数',
                value: settings.mapsX,
                onChanged: (v) => notifier.setMaps(x: v),
              ),
              _Stepper(
                label: '纵向张数',
                value: settings.mapsY,
                onChanged: (v) => notifier.setMaps(y: v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: '作品模式',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AdaptiveSegments<ArtKind>(
                segments: const [
                  ButtonSegment(
                    value: ArtKind.blockPixels,
                    label: Text('方块像素画'),
                  ),
                  ButtonSegment(value: ArtKind.mapItem, label: Text('地图画')),
                ],
                selected: {settings.artKind},
                onSelectionChanged: (v) => notifier.setArtKind(v.first),
              ),
              const SizedBox(height: 8),
              Text(
                settings.artKind == ArtKind.blockPixels
                    ? '使用方块顶面贴图，一层平面；不等同于地图物品的颜色。'
                    : settings.flatMap
                    ? '使用同一高度的游戏地图颜色，重新配色并生成单层投影。'
                    : '使用游戏地图色表，通过高度变化产生明暗。',
              ),
              if (settings.artKind == ArtKind.mapItem) ...[
                const SizedBox(height: 8),
                AdaptiveSegments<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('阶梯地图画')),
                    ButtonSegment(value: true, label: Text('单层地图画')),
                  ],
                  selected: {settings.flatMap},
                  onSelectionChanged: (v) => notifier.setFlatMap(v.first),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: '构图',
          child: Column(
            children: [
              AdaptiveSegments<CropMode>(
                segments: const [
                  ButtonSegment(value: CropMode.contain, label: Text('完整保留')),
                  ButtonSegment(value: CropMode.cover, label: Text('裁剪铺满')),
                ],
                selected: {settings.cropMode},
                onSelectionChanged: (v) => notifier.setCropMode(v.first),
              ),
              const SizedBox(height: 8),
              Text(
                settings.cropMode == CropMode.contain
                    ? '保持比例，空余区域使用背景色。'
                    : '保持比例，超出画布的内容会裁去。',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: '配色',
          child: Column(
            children: [
              AdaptiveSegments<DitherMode>(
                segments: const [
                  ButtonSegment(value: DitherMode.none, label: Text('纯色')),
                  ButtonSegment(
                    value: DitherMode.floydSteinberg,
                    label: Text('抖动'),
                  ),
                ],
                selected: {settings.dither},
                onSelectionChanged: (v) => notifier.setDither(v.first),
              ),
              const SizedBox(height: 8),
              const _MaxBlocksRow(),
              ExpansionTile(
                title: const Text('高级配色'),
                initiallyExpanded: false,
                tilePadding: EdgeInsets.zero,
                children: [
                  AdaptiveSegments<ColorMetric>(
                    segments: const [
                      ButtonSegment(
                        value: ColorMetric.chromaWeighted,
                        label: Text('保色'),
                      ),
                      ButtonSegment(
                        value: ColorMetric.cie76,
                        label: Text('标准色差'),
                      ),
                    ],
                    selected: {settings.metric},
                    onSelectionChanged: (v) => notifier.setMetric(v.first),
                  ),
                  if (settings.dither == DitherMode.floydSteinberg) ...[
                    _SliderRow(
                      label: '抖动阈值',
                      value: settings.ditherThreshold,
                      min: 0,
                      max: 24,
                      divisions: 24,
                      display: settings.ditherThreshold.toStringAsFixed(0),
                      hint: '调高使平坦区域更干净',
                      onChanged: notifier.setDitherThreshold,
                    ),
                    _SliderRow(
                      label: '抖动强度',
                      value: settings.ditherStrength,
                      min: 0,
                      max: 1,
                      divisions: 20,
                      display: '${(settings.ditherStrength * 100).round()}%',
                      hint: '调低减少噪点，但平均颜色近似可能变差',
                      onChanged: notifier.setDitherStrength,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: '游戏版本',
          subtitle: '目标版本由随附游戏数据固定',
          child: versions == null
              ? const LinearProgressIndicator()
              : Text(
                  '${versions.latest.id}'
                  '  ·  DataVersion ${versions.latest.dataVersion}'
                  '  ·  Y ${versions.latest.minY}..${versions.latest.maxY}',
                ),
        ),
        const SizedBox(height: 16),
        _PaletteSection(),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: source == null || result.isLoading ? null : onGenerate,
          icon: result.isLoading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome),
          label: Text(
            result.isLoading
                ? '生成中…'
                : result.value == null
                ? '生成预览'
                : '重新生成',
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '改任何参数都会自动重新生成,这个按钮只是备用。',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        const _ResultSummary(),
      ],
    );
  }
}

class _SourcePicker extends ConsumerWidget {
  const _SourcePicker({required this.settings, required this.source});

  final ProjectSettings settings;
  final SourceImage? source;

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final sourceNotifier = ref.read(sourceImageProvider.notifier);
    final importRevision = sourceNotifier.beginImport();
    try {
      final file = await FilePicker.pickFile(
        type: FileType.image,
        dialogTitle: '选择一张图片',
      );
      if (file == null || !context.mounted) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) throw const FormatException('文件内容为空');
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        final width = frame.image.width;
        final height = frame.image.height;
        frame.image.dispose();
        if (!context.mounted) return;
        sourceNotifier.completeImport(
          importRevision,
          SourceImage(
            name: file.name,
            bytes: bytes,
            width: width,
            height: height,
          ),
        );
      } finally {
        codec.dispose();
      }
    } on Object catch (error) {
      if (!context.mounted || !sourceNotifier.isCurrentImport(importRevision)) {
        return;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('无法读取图片：$error。请换一张图片重试。')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return _Section(
      title: '原图',
      child: Row(
        children: [
          Expanded(
            child: Text(
              source == null
                  ? '还没有选图片'
                  : '${source!.name}  ${source!.width}x${source!.height}',
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: source == null ? scheme.outline : null),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: () => _pick(context, ref),
            icon: const Icon(Icons.folder_open),
            label: Text(source == null ? '选择' : '换一张'),
          ),
        ],
      ),
    );
  }
}

class _PaletteSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_PaletteSection> createState() => _PaletteSectionState();
}

class _PaletteSectionState extends ConsumerState<_PaletteSection> {
  /// Which colours are showing their blocks. Collapsed by default: there are
  /// sixty of them, and every one of them expanded is a page and a half of
  /// scrolling before you reach anything else.
  final Set<int> _expanded = <int>{};

  bool _open = true;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final table = ref.watch(colorTableProvider).value;
    final palette = ref.watch(paletteProvider);
    final settings = ref.watch(settingsProvider);
    final names = ref.watch(blockNamesProvider).value ?? BlockNames.empty;
    if (table == null || palette == null) {
      return const _Section(title: '调色板', child: LinearProgressIndicator());
    }

    final notifier = ref.read(settingsProvider.notifier);
    final disabled = settings.disabledBlockKeys;

    // Counted per colour rather than flat, because the colour is what decides
    // whether a pixel can be reproduced at all and the blocks are only the
    // choice of what to build it out of.
    var enabledBlocks = 0;
    for (final entry in palette.entries) {
      if (!disabled.contains(entry.key)) enabledBlocks++;
    }

    final groups = <({int index, String name, List<PaletteEntry> entries})>[];
    if (settings.artKind == ArtKind.mapItem) {
      for (final color in table.colors) {
        final entries = palette
            .entriesForColor(color.index)
            .where(
              (e) =>
                  _query.isEmpty ||
                  '${names.zhOr(e.blockId, e.blockName)} ${e.blockName} ${e.blockId}'
                      .toLowerCase()
                      .contains(_query),
            )
            .toList();
        if (entries.isNotEmpty) {
          groups.add((index: color.index, name: color.name, entries: entries));
        }
      }
    } else {
      const labels = ['混凝土', '羊毛', '木材', '陶瓦', '其他方块'];
      for (var category = 0; category < labels.length; category++) {
        final entries = palette.entries.where((e) {
          final id = e.blockId;
          final group = id.contains('concrete')
              ? 0
              : id.contains('wool')
              ? 1
              : (id.contains('planks') ||
                    id.contains('log') ||
                    id.contains('wood'))
              ? 2
              : id.contains('terracotta')
              ? 3
              : 4;
          return group == category &&
              (_query.isEmpty ||
                  '${names.zhOr(id, e.blockName)} ${e.blockName} $id'
                      .toLowerCase()
                      .contains(_query));
        }).toList();
        if (entries.isNotEmpty) {
          groups.add((
            index: 100 + category,
            name: labels[category],
            entries: entries,
          ));
        }
      }
    }

    final allKeys = [for (final entry in palette.entries) entry.key];
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  _open ? Icons.expand_more : Icons.chevron_right,
                  size: 20,
                  color: scheme.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  '调色板',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${palette.length} 种方块色 · '
                    '$enabledBlocks/${palette.length} 方块',
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!_open) const SizedBox(height: 8),
        if (_open) ...[
          TextField(
            decoration: const InputDecoration(
              hintText: '搜索候选方块',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
            onChanged: (value) => setState(() => _query = value.toLowerCase()),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('关闭候选会重新配色；仅隐藏显示请到「材料」页。'),
          ),
          TextButton.icon(
            icon: const Icon(Icons.info_outline),
            label: const Text('查看不可用方块及原因'),
            onPressed: () {
              final rules = ref.read(blockCapabilitiesProvider).value;
              if (rules == null) return;
              final reasons = rules
                  .reasonsFor(settings.artKind)
                  .entries
                  .toList();
              showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('不可用方块'),
                  content: SizedBox(
                    width: 420,
                    height: 360,
                    child: ListView.builder(
                      itemCount: reasons.length,
                      itemBuilder: (_, i) => ListTile(
                        dense: true,
                        title: Text(reasons[i].key),
                        subtitle: Text(reasons[i].value),
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              TextButton(
                onPressed: () => notifier.setBlocksEnabled(true, allKeys),
                child: const Text('全开'),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: () => notifier.setBlocksEnabled(false, allKeys),
                child: const Text('全关'),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() {
                  if (_expanded.length == groups.length) {
                    _expanded.clear();
                  } else {
                    _expanded
                      ..clear()
                      ..addAll(groups.map((g) => g.index));
                  }
                }),
                child: Text(_expanded.isEmpty ? '全部展开' : '全部收起'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 360,
            child: ListView.builder(
              itemCount: groups.length,
              itemBuilder: (context, index) {
                final group = groups[index];
                final enabled = group.entries
                    .where((e) => !disabled.contains(e.key))
                    .length;
                return _ColorGroup(
                  names: names,
                  colorIndex: group.index,
                  name: group.name,
                  preview: group.entries.first,
                  entries: group.entries,
                  disabled: disabled,
                  expanded:
                      _query.isNotEmpty || _expanded.contains(group.index),
                  enabledCount: enabled,
                  totalCount: group.entries.length,
                  onToggleExpanded: () => setState(() {
                    if (!_expanded.remove(group.index)) {
                      _expanded.add(group.index);
                    }
                  }),
                  onToggle: notifier.setBlockEnabled,
                  onToggleAll: (on) => notifier.setBlocksEnabled(
                    on,
                    group.entries.map((e) => e.key),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

/// One base colour: a summary row, and its blocks once opened.
///
/// Collapsed, the row carries enough to work with — the colour itself as a
/// shade strip, how many of its blocks are on, and a switch for the lot. Open,
/// it lists the blocks *by name*, because a row of identical swatches tells you
/// nothing about which one you are switching off.
class _ColorGroup extends StatelessWidget {
  const _ColorGroup({
    required this.colorIndex,
    this.names = BlockNames.empty,
    required this.name,
    required this.preview,
    required this.entries,
    required this.disabled,
    required this.expanded,
    required this.enabledCount,
    required this.totalCount,
    required this.onToggleExpanded,
    required this.onToggle,
    required this.onToggleAll,
  });

  final int colorIndex;
  final BlockNames names;
  final String name;
  final PaletteEntry? preview;
  final List<PaletteEntry> entries;
  final Set<String> disabled;
  final bool expanded;
  final int enabledCount;
  final int totalCount;
  final VoidCallback onToggleExpanded;
  final void Function(String key, bool enabled) onToggle;
  final void Function(bool enabled) onToggleAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = enabledCount > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: ValueKey('color-$colorIndex'),
          onTap: entries.isEmpty ? null : onToggleExpanded,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: entries.isEmpty
                      ? null
                      : Icon(
                          expanded ? Icons.expand_more : Icons.chevron_right,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                ),
                if (preview != null)
                  Opacity(
                    opacity: on ? 1 : 0.3,
                    child: _ShadeStrip(entry: preview!, width: 14, height: 14),
                  ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: on ? scheme.onSurfaceVariant : scheme.outline,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (entries.isEmpty)
                  Text(
                    '没有可用的实心方块',
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  )
                else ...[
                  Text(
                    '$enabledCount/$totalCount',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: on ? scheme.onSurfaceVariant : scheme.outline,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (totalCount > 1)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: InkWell(
                        onTap: () => onToggleAll(enabledCount < totalCount),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          child: Text(
                            enabledCount < totalCount ? '全开' : '全关',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: scheme.primary),
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        if (expanded && entries.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 24, top: 2, bottom: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final entry in entries)
                  _BlockChip(
                    key: ValueKey(entry.key),
                    entry: entry,
                    label: names.zhOr(entry.blockId, entry.blockName),
                    enabled: !disabled.contains(entry.key),
                    onTap: () =>
                        onToggle(entry.key, disabled.contains(entry.key)),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The three shades of one entry, as a small horizontal strip.
class _ShadeStrip extends StatelessWidget {
  const _ShadeStrip({
    required this.entry,
    required this.width,
    required this.height,
  });

  final PaletteEntry entry;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Row(
        children: [
          for (final tier in ShadeTier.staircase)
            Expanded(
              child: ColoredBox(
                color: Color.fromARGB(
                  255,
                  entry.tone(tier).r,
                  entry.tone(tier).g,
                  entry.tone(tier).b,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// One block, named.
///
/// Deliberately a labelled chip rather than a bare swatch: every block of a
/// colour renders the same on a map, so a row of identical squares is exactly
/// what a correct palette looks like — and exactly what is useless to click on,
/// because nothing distinguishes "White Wool" from "White Concrete".
class _BlockChip extends StatelessWidget {
  const _BlockChip({
    super.key,
    required this.entry,
    this.label,
    required this.enabled,
    required this.onTap,
  });

  final PaletteEntry entry;
  final String? label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final notes = <String>[
      entry.name,
      if (entry.needsSupport) '需要支撑',
      if (entry.flammable) '易燃',
    ];

    return Tooltip(
      message: '${entry.blockName}\n${notes.join(' · ')}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Opacity(
          opacity: enabled ? 1 : 0.35,
          child: Container(
            padding: const EdgeInsets.fromLTRB(4, 3, 9, 3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: enabled ? scheme.outlineVariant : scheme.outline,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ShadeStrip(entry: entry, width: 13, height: 13),
                const SizedBox(width: 6),
                Text(
                  label ?? entry.blockName,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
                  ),
                ),
                if (entry.flammable) ...[
                  const SizedBox(width: 3),
                  Icon(
                    Icons.local_fire_department,
                    size: 11,
                    color: scheme.error,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultSummary extends ConsumerWidget {
  const _ResultSummary();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(resultProvider);
    final scheme = Theme.of(context).colorScheme;

    return result.when(
      loading: () => const SizedBox.shrink(),
      error: (error, _) => _Section(
        title: '出错了',
        child: Text('$error', style: TextStyle(color: scheme.error)),
      ),
      data: (data) {
        if (data == null) return const SizedBox.shrink();
        return _Section(
          title: '结果',
          subtitle:
              '${data.width}x${data.height} 像素 · '
              '耗时 ${data.elapsed.inMilliseconds} ms',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Fact(
                label: '高度范围',
                value:
                    'Y ${data.minHeight}..${data.maxHeight} '
                    '(${data.blockHeightSpan} 层)',
              ),
              _Fact(
                label: '参照行',
                value:
                    'Y ${data.referenceRowHeight}'
                    ' (地图北边要多建这一行)',
              ),
              _Fact(label: '可用颜色', value: '${data.paletteBlocks} 种方块色'),
              _Fact(
                label: '抖动像素',
                value:
                    '${data.ditheredPixels} / '
                    '${data.width * data.height}',
              ),
              _Fact(
                label: '实际用到方块',
                value:
                    '${data.blocksUsed} 种 · '
                    '前 20 种覆盖 '
                    '${(data.top20Coverage * 100).toStringAsFixed(0)}% · '
                    '前 40 种覆盖 '
                    '${(data.top40Coverage * 100).toStringAsFixed(0)}%',
              ),
              _Fact(
                label: '色差(模糊后)',
                value:
                    '${data.blurredMeanError.toStringAsFixed(2)} ΔE'
                    ' · 逐像素 ${data.pixelMeanError.toStringAsFixed(2)}',
              ),
              for (final warning in data.warnings)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        data.fitsWorld
                            ? Icons.info_outline
                            : Icons.warning_amber,
                        size: 16,
                        color: data.fitsWorld ? scheme.outline : scheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          warning,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: data.fitsWorld
                                    ? scheme.outline
                                    : scheme.error,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
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

class _Section extends StatelessWidget {
  const _Section({required this.title, this.subtitle, required this.child});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              subtitle!,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton.outlined(
          onPressed: value > 1 ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove),
          tooltip: '减少$label',
          visualDensity: VisualDensity.compact,
        ),
        SizedBox(
          width: 48,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        IconButton.outlined(
          onPressed: value < 16 ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add),
          tooltip: '增加$label',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.hint,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final String hint;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            Text(display, style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
        AccessibleSlider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: display,
          semanticFormatterCallback: (_) => '$label $display',
          onChanged: onChanged,
        ),
        Text(
          hint,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// "At most N blocks", as a slider with an off position at the far right.
///
/// The cap is a second matching pass, so it costs one more solve. The readout
/// below says what the last run actually used and how much of the picture the
/// most-used blocks covered, which is the number that decides whether the cap
/// is worth it.
class _MaxBlocksRow extends ConsumerWidget {
  const _MaxBlocksRow();

  static const int _off = 320;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final value = (settings.maxBlocks ?? _off).clamp(4, _off);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Text('最多用几种方块')),
            Text(
              settings.maxBlocks == null ? '不限' : '${settings.maxBlocks}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ],
        ),
        AccessibleSlider(
          value: value.toDouble(),
          min: 4,
          max: _off.toDouble(),
          divisions: (_off - 4) ~/ 4,
          label: settings.maxBlocks == null ? '不限' : '${settings.maxBlocks}',
          semanticFormatterCallback: (v) =>
              '最多使用${v.round() >= _off ? "不限" : v.round()}种方块',
          onChanged: (v) =>
              notifier.setMaxBlocks(v.round() >= _off ? null : v.round()),
        ),
        Text(
          '一张图通常用不上几百种方块。先匹配一遍,把用得最多的留下,'
          '再按这些重新匹配。种类少,物品栏更好翻,噪点也少一些,代价是颜色略受限。',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
