import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapart_core/mapart_core.dart';
import 'package:material_ui/material_ui.dart';

import '../widgets/adaptive_segments.dart';

import '../data/export.dart';
import '../data/export_job.dart';
import '../data/preferences.dart';
import '../state/project.dart';
import '../window/window_controls.dart';

/// The export page: what to write, in what shape, and where it went.
///
/// The two choices that matter are on it rather than buried: whether the
/// schematic is the surface only or the whole solid mass, and whether it carries
/// the reference row. Both change what you have to build, and neither is
/// obvious from a file name.
class ExportPage extends ConsumerStatefulWidget {
  const ExportPage({super.key});

  @override
  ConsumerState<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends ConsumerState<ExportPage> {
  ExportOptions _options = const ExportOptions();
  MapPlan? _lastPlan;
  final _nameController = TextEditingController(text: 'mapart');
  int _optionRevision = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreOptions());
  }

  Future<void> _restoreOptions() async {
    final revision = _optionRevision;
    final saved = await Preferences.loadExportOptions();
    if (!mounted || revision != _optionRevision || saved == null) return;
    setState(() {
      _options = saved.copyWith(
        includeReferenceRow: _lastPlan == null
            ? saved.includeReferenceRow
            : saved.referenceRows[_lastPlan!.artKind] ??
                  _lastPlan!.requiresReferenceRow,
      );
      _nameController.text = saved.baseName;
    });
  }

  void _rememberOptions(ExportOptions options) {
    _optionRevision++;
    _options = options;
    unawaited(Preferences.saveExportOptions(options));
  }

  bool _busy = false;
  String _step = '';
  ExportResult? _result;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(resultProvider);
    final plan = result.value?.plan;
    if (plan != null && !identical(plan, _lastPlan)) {
      _lastPlan = plan;
      _options = _options.copyWith(
        includeReferenceRow:
            _options.referenceRows[plan.artKind] ?? plan.requiresReferenceRow,
      );
      if (!_busy) _result = null;
    }
    final source = ref.watch(sourceImageProvider);
    final directory = ref.watch(exportDirectoryProvider);

    return Scaffold(
      body: plan == null
          ? _EmptyState(
              loading: result.isLoading,
              message: result.hasError ? '${result.error}' : null,
            )
          : CustomScrollView(
              slivers: [
                const SliverAppBar.large(title: Text('导出')),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  sliver: SliverList.list(
                    children: _sections(plan, source?.name, directory),
                  ),
                ),
              ],
            ),
    );
  }

  List<Widget> _sections(
    MapPlan plan,
    String? sourceName,
    String? directory,
  ) => [
    _Section(
      title: '文件',
      subtitle:
          '${plan.mapsX} x ${plan.mapsY} 张地图 · '
          '${plan.width} x ${plan.height} 格 · '
          'Minecraft ${plan.versionId}',
      child: Column(
        children: [
          for (final format in ExportFormat.values)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _options.formats.contains(format),
              title: Text(format.label),
              subtitle: Text(_describe(format, plan)),
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      final next = Set<ExportFormat>.from(_options.formats);
                      if (value ?? false) {
                        next.add(format);
                      } else {
                        next.remove(format);
                      }
                      _rememberOptions(_options.copyWith(formats: next));
                    }),
            ),
        ],
      ),
    ),
    const SizedBox(height: 8),
    _Section(
      title: '投影内容',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (plan.artKind == ArtKind.mapItem) ...[
            Text(plan.isFlatMap ? '当前作品：单层地图画 · 所有方块同高' : '当前作品：阶梯地图画'),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => ref
                        .read(settingsProvider.notifier)
                        .setFlatMap(!plan.isFlatMap),
              child: Text(plan.isFlatMap ? '改为阶梯地图画' : '改为单层地图画并重新配色'),
            ),
          ],
          AdaptiveSegments<ExportShape>(
            segments: const [
              ButtonSegment(
                value: ExportShape.surface,
                label: Text('只要表层'),
                icon: Icon(Icons.layers_outlined),
              ),
              ButtonSegment(
                value: ExportShape.solid,
                label: Text('实心'),
                icon: Icon(Icons.view_module_outlined),
              ),
            ],
            selected: {_options.shape},
            onSelectionChanged: _busy
                ? null
                : (value) => setState(
                    () =>
                        _rememberOptions(_options.copyWith(shape: value.first)),
                  ),
          ),
          const SizedBox(height: 8),
          Text(
            plan.blockHeightSpan == 1
                ? '单层作品只放一层方块；表层与实心的方块数量相同。'
                : _options.shape == ExportShape.surface
                ? '每列只放最上面那一块,投影就是一张阶梯壳:'
                      '自己先铺好地面,再照着幽灵方块一块块放。文件小,'
                      'Litematica 也轻快。'
                : '从最低一层填到表层,和盖完的样子一致。'
                      '方块数会大很多:一张地图约 50 万个,'
                      '5x5 能到九千万,文件几十 MB,'
                      'Litematica 渲染起来会很吃力。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: _options.includeReferenceRow,
            title: const Text('包含最北边的参照行'),
            subtitle: Text(
              'Y ${plan.referenceRowHeight} 那一行,'
              '${plan.width} 个方块。它在图外,但第一行的明暗靠它,'
              '地图画建议留着；方块像素画不需要此行。',
            ),
            onChanged: _busy
                ? null
                : (value) => setState(
                    () => _rememberOptions(
                      _options.copyWith(
                        includeReferenceRow: value,
                        referenceRows: {
                          ..._options.referenceRows,
                          plan.artKind: value,
                        },
                      ),
                    ),
                  ),
          ),
        ],
      ),
    ),
    const SizedBox(height: 16),
    _Section(
      title: '文件名与位置',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _nameController,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: '文件名前缀',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) => setState(
              () => _rememberOptions(_options.copyWith(baseName: value)),
            ),
          ),
          const SizedBox(height: 8),
          _Destination(
            directory: directory,
            onPick: _busy ? null : () => _pickDirectory(context),
            onForget: () =>
                ref.read(exportDirectoryProvider.notifier).set(null),
          ),
        ],
      ),
    ),
    const SizedBox(height: 16),
    FilledButton.icon(
      onPressed: _busy || plan.blocks.isEmpty || _options.formats.isEmpty
          ? null
          : () => _export(plan, sourceName),
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.file_download),
      label: Text(_busy ? _step : '导出'),
    ),
    if (_error != null) ...[
      const SizedBox(height: 12),
      Text(
        _error!,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    ],
    if (_result != null) ...[
      const SizedBox(height: 16),
      _ResultCard(result: _result!),
    ],
  ];

  /// One line per format saying what it is for, and — for the schematics — how
  /// big it will be, because that is the number that decides whether "solid"
  /// is a good idea.
  String _describe(ExportFormat format, MapPlan plan) {
    final blocks = _options.shape == ExportShape.solid
        ? _solidBlocks(plan)
        : plan.totalBlocks + (_options.includeReferenceRow ? plan.width : 0);
    return switch (format) {
      ExportFormat.litematic =>
        'Litematica 的投影文件,放进投影文件夹后游戏里直接加载 · '
            '约 ${_count(blocks)} 个方块',
      ExportFormat.schem =>
        'Sponge v2,WorldEdit 和大部分原理图工具都认 · 约 ${_count(blocks)} 个方块',
      ExportFormat.pdf => '总览、逐张图纸和材料清单；较长的图例自动分页',
      ExportFormat.png => '和 PDF 同样的版式,每张地图一张,另加一张总览',
      ExportFormat.csv => '材料清单,带 BOM,Excel 打开不乱码',
    };
  }

  int _solidBlocks(MapPlan plan) => BuildSummary.fromPlan(
    plan,
    shape: ExportShape.solid,
    includeReferenceRow: _options.includeReferenceRow,
  ).totalBlocks;

  static String _count(int value) => value >= 10000000
      ? '${(value / 10000000).toStringAsFixed(1)} 千万'
      : value >= 10000
      ? '${(value / 10000).toStringAsFixed(1)} 万'
      : '$value';

  Future<void> _pickDirectory(BuildContext context) async {
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: '导出到哪个文件夹',
      initialDirectory: ref.read(exportDirectoryProvider),
    );
    if (picked == null) return;
    ref.read(exportDirectoryProvider.notifier).set(picked);
  }

  Future<void> _export(MapPlan plan, String? sourceName) async {
    final options = _options.copyWith(baseName: _nameController.text);
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _step = '准备中…';
    });

    try {
      String? directory = ref.read(exportDirectoryProvider);
      if (WindowControls.isDesktop && directory == null) {
        directory = await defaultExportDirectory();
        if (!mounted) return;
        if (directory != null) {
          ref.read(exportDirectoryProvider.notifier).set(directory);
        }
      }
      final destination = directory;
      final result = await executeExport(
        plan: plan,
        options: options,
        sourceName: sourceName,
        loadFont: _fontBytes,
        onProgress: (step) {
          if (mounted) setState(() => _step = step);
        },
        save: (file) async {
          if (!mounted) return null;
          return saveExportedFile(file, destination, onConflict: _conflict);
        },
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step = '';
        _result = result;
      });
    } on Object catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step = '';
        _error = '导出失败：$error';
      });
      debugPrint('$stack');
    }
  }

  Future<ExistingFileAction> _conflict(String path) async {
    if (!mounted) return ExistingFileAction.skip;
    return await showDialog<ExistingFileAction>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('文件已经存在'),
            content: Text(path),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, ExistingFileAction.skip),
                child: const Text('跳过'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, ExistingFileAction.rename),
                child: const Text('改名保存'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, ExistingFileAction.overwrite),
                child: const Text('覆盖'),
              ),
            ],
          ),
        ) ??
        ExistingFileAction.skip;
  }

  Future<Uint8List> _fontBytes(String name) async {
    final data = await rootBundle.load('assets/fonts/$name');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}

class _Destination extends StatelessWidget {
  const _Destination({
    required this.directory,
    required this.onPick,
    required this.onForget,
  });

  final String? directory;
  final VoidCallback? onPick;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final desktop = WindowControls.isDesktop;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.folder_outlined,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                desktop
                    ? directory ?? '还没有选文件夹,导出时会问一次'
                    : '手机上没有可写的固定文件夹,每个文件会走系统保存对话框',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
        if (desktop)
          Row(
            children: [
              TextButton(onPressed: onPick, child: const Text('选择文件夹')),
              if (directory != null)
                TextButton(onPressed: onForget, child: const Text('清除')),
            ],
          ),
        Text(
          '不写死 .minecraft/schematics:每个启动器的实例目录都不一样,'
          '猜错了会写到一个不存在的文件夹里。',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final ExportResult result;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '已保存 ${result.files.where((f) => f.path != null).length}/${result.files.length} 个文件 · '
              '${_size(result.totalBytes)} · '
              '${result.elapsed.inMilliseconds} ms',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            for (final file in result.files)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      file.path == null
                          ? Icons.error_outline
                          : Icons.check_circle_outline,
                      size: 16,
                      color: file.path == null ? scheme.error : scheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${file.path ?? file.name} · ${file.status}',
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      _size(file.size),
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            for (final file in result.files.where((f) => f.error != null))
              Text(
                '${file.name}：${file.error}',
                style: TextStyle(color: scheme.error),
              ),
            for (final warning in result.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  warning,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.error),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              '把 .litematic 放进 Litematica 的投影文件夹(在游戏里看「投影」设置),'
              '.schem 用 WorldEdit 的 //schem load 加载。'
              '这两个文件都还没有在游戏里实测过,见 README。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  static String _size(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).toStringAsFixed(0)} KB';
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
                Icons.ios_share_outlined,
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
