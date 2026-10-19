// Generates a complete block -> map colour table from the decompiled game
// itself, and diffs it against the vendored MapartCraft table.
//
// Inputs (produced by hand, see doc/block_table.md):
//   tool/data/src/MapColor.java  — decompiled MapColor class (id, rgb) pairs
//   tool/data/src/Blocks.java    — decompiled Blocks class (registrations)
//
// Outputs:
//   tool/data/generated_block_colors.json — every registered block with its
//       map colour, constructor class and flammability, straight from the game
//   a stdout report: vendored blocks whose colour disagrees with the game,
//       and full-cube blocks the vendored table does not know about.
//
// Usage, from the mapart_core package root:
//   dart run tool/gen_block_table.dart
import 'dart:convert';
import 'dart:io';

void main() {
  final mapColorSrc = File('tool/data/src/MapColor.java').readAsStringSync();
  final blocksSrc = File('tool/data/src/Blocks.java').readAsStringSync();

  // ---- MapColor.java: name -> (id, rgb) ----
  final colorByName = <String, ({int id, int rgb})>{};
  final colorRe = RegExp(
    r'public static final MapColor (\w+) = new MapColor\((\d+), (\d+)\)',
  );
  for (final m in colorRe.allMatches(mapColorSrc)) {
    colorByName[m.group(1)!] = (
      id: int.parse(m.group(2)!),
      rgb: int.parse(m.group(3)!),
    );
  }
  stdout.writeln('map colours parsed: ${colorByName.length}');

  // ---- Blocks.java: registrations ----
  // A registration spans from `FIELD = register(` to the closing `);`.
  final regRe = RegExp(r'public static final \w+ (\w+) = (register\w*)\(');
  final registrations = <String, String>{};
  final regKinds = <String, String>{};
  var pos = 0;
  while (true) {
    final m = regRe.firstMatch(blocksSrc.substring(pos));
    if (m == null) break;
    final field = m.group(1)!;
    final kind = m.group(2)!;
    final start = pos + m.end;
    // The closing is the first `\n   );` after the start (decompiler format).
    final end = blocksSrc.indexOf('\n   );', start);
    final sameLine = blocksSrc.indexOf(');', start);
    final body = (end == -1 || (sameLine != -1 && sameLine < end))
        ? blocksSrc.substring(start, sameLine + 2)
        : blocksSrc.substring(start, end + 6);
    registrations[field] = body;
    regKinds[field] = kind;
    pos = start + 10;
  }
  stdout.writeln('registrations parsed: ${registrations.length}');

  // Per registration: id, class, color expression, flammability.
  final idRe = RegExp(r'"([a-z0-9_./]+)"');
  final classRe = RegExp(r'(\w+)::new');
  final directRe = RegExp(r'mapColor\(MapColor\.(\w+)\)');
  final indirectRe = RegExp(r'mapColor\((\w+)\.defaultMapColor\(\)\)');
  // Pillar helpers take (topColor, sideColor, sound): the decompiled body of
  // logProperties is `.mapColor(state -> axis == Y ? topColor : sideColor)`,
  // so the FIRST argument is what a map sees on an upright log, and also what
  // defaultMapColor() (the default state is axis=y) reports.
  final logRe = RegExp(
    r'(?:log|stem|bambooStem)Properties\(\s*([^,]+),\s*([^,]+),',
  );
  // Single-colour helpers, e.g. netherStemProperties(MapColor.CRIMSON_STEM).
  final monoRe = RegExp(r'\w+Properties\(\s*MapColor\.(\w+)\s*\)');

  ({String? direct, String? indirect, String? logSide, String? logTop})?
  colorExprOf(String body) {
    final direct = directRe.firstMatch(body)?.group(1) ??
        monoRe.firstMatch(body)?.group(1);
    final indirect = indirectRe.firstMatch(body)?.group(1);
    String? logSide;
    String? logTop;
    final lm = logRe.firstMatch(body);
    if (lm != null) {
      // First helper argument is the TOP colour, second is the side.
      logTop = lm.group(1)!.trim();
      logSide = lm.group(2)!.trim();
    }
    if (direct == null && indirect == null && logTop == null) {
      // leavesProperties() hard-codes MapColor.PLANT. See the decompiled helper.
      if (body.contains('leavesProperties(')) {
        return (
          direct: 'PLANT',
          indirect: null,
          logSide: null,
          logTop: null,
        );
      }
      return null;
    }
    return (direct: direct, indirect: indirect, logSide: logSide, logTop: logTop);
  }

  String? colorNameOfToken(String token) {
    final d = RegExp(r'MapColor\.(\w+)').firstMatch(token);
    if (d != null) return d.group(1);
    final i = RegExp(r'(\w+)\.defaultMapColor\(\)').firstMatch(token);
    if (i != null) return 'FIELD:${i.group(1)}';
    return null;
  }

  // Resolve to a MapColor *name*, following field references recursively.
  final resolvedCache = <String, String?>{};
  String? resolveField(String field, [int depth = 0]) {
    if (resolvedCache.containsKey(field)) return resolvedCache[field];
    if (depth > 8) return null;
    final body = registrations[field];
    if (body == null) return null;
    final expr = colorExprOf(body);
    if (expr == null) return null;
    String? name = expr.direct;
    if (name == null && expr.indirect != null) {
      name = resolveField(expr.indirect!, depth + 1);
    }
    if (name == null && expr.logTop != null) {
      // defaultMapColor() of a pillar is the colour of its default state,
      // which is axis=y: the TOP colour.
      final token = colorNameOfToken(expr.logTop!);
      if (token != null && token.startsWith('FIELD:')) {
        name = resolveField(token.substring(6), depth + 1);
      } else {
        name = token;
      }
    }
    resolvedCache[field] = name;
    return name;
  }

  String? resolveTopColor(String field, [int depth = 0]) {
    if (depth > 8) return null;
    final body = registrations[field];
    if (body == null) return null;
    final expr = colorExprOf(body);
    if (expr == null) return null;
    if (expr.logTop != null) {
      final token = colorNameOfToken(expr.logTop!);
      if (token != null && token.startsWith('FIELD:')) {
        // The top colour may reference another block's defaultMapColor.
        return resolveField(token.substring(6), depth + 1);
      }
      return token;
    }
    // Not a pillar: the top is the default colour.
    if (expr.direct != null) return expr.direct;
    if (expr.indirect != null) return resolveField(expr.indirect!, depth + 1);
    return null;
  }

  // Full-cube constructor classes we trust for a staircase. Everything with
  // a shape (slabs, stairs, fences, panes, carpets...) is excluded.
  const fullCubeClasses = {
    'Block',
    'RotatedPillarBlock',
    'HugeMushroomBlock',
    'GlazedTerracottaBlock',
    'HalfTransparentBlock',
    'TransparentBlock', // glass shows its colour on maps
    'LeavesBlock',
    'ConcretePowderBlock',
    'FallingBlock',
    'ColoredFallingBlock',
    'GravelBlock',
    'SandBlock',
    'RedSandBlock',
    'RedStoneBlock',
    'RedstoneBlock',
    'PoweredBlock',
    'TargetBlock',
    'SpongeBlock',
    'WetSpongeBlock',
    'SlimeBlock',
    'HoneyBlock',
    'HayBlock',
    'NetheriteBlock',
    'BeaconBlock',
    'SeaLanternBlock',
    'GlowstoneBlock',
    'ShroomlightBlock',
    'FroglightsBlock',
    'FroglightBlock',
    'MagmaBlock',
    'BoneBlock',
    'DriedKelpBlock',
    'CoralBlock',
    'NyliumBlock',
    'FungusBlock',
    'MyceliumBlock',
    'GrassBlock',
    'DirtPathBlock',
    'PodzolBlock',
    'MudBlock',
    'ClayBlock',
    'IceBlock',
    'PackedIceBlock',
    'BlueIceBlock',
    'SnowBlock',
    'PowderSnowBlock',
    'CactusBlock',
    'PumpkinBlock',
    'CarvedPumpkinBlock',
    'MelonBlock',
    'JackOLanternBlock',
    'TerracottaBlock',
    'NoteBlock',
    'JukeboxBlock',
    'CraftingTableBlock',
    'CartographyTableBlock',
    'FletchingTableBlock',
    'SmithingTableBlock',
    'LoomBlock',
    'ComposterBlock',
    'BarrelBlock',
    'SmokerBlock',
    'BlastFurnaceBlock',
    'FurnaceBlock',
    'ObserverBlock',
    'DispenserBlock',
    'DropperBlock',
    'PistonBaseBlock',
    'TntBlock',
    'BookshelfBlock',
    'ChiseledBookShelfBlock',
    'LodestoneBlock',
    'RespawnAnchorBlock',
    'AncientDebrisBlock',
    'CryingObsidianBlock',
    'ObsidianBlock',
    'BedrockBlock',
    'EndStoneBlock',
    'PurpurBlock',
    'PillarBlock',
    'QuartzBlock',
    'CoralPlantBlock',
    'CopperBlock',
    'WeatheringCopperFullBlock',
    'WeatheringCopper',
    'IronBarsBlock',
    'CreakingHeartBlock',
    'EyeblossomBlock',
    'ResinBlock',
    'TestBlock',
    'TestInstanceBlock',
    'DryGrassBlock',
  };

  // ---- emit the generated table ----
  final out = <String, dynamic>{};
  final unparseable = <String>[];
  for (final e in registrations.entries) {
    final field = e.key;
    final body = e.value;
    final kind = regKinds[field] ?? 'register';
    // `register(BlockIds.DIRT, ...)` has no quoted id; the field is the id.
    var id = idRe.firstMatch(body)?.group(1);
    if (id == null || id.contains('/')) id = field.toLowerCase();
    final className = classRe.firstMatch(body)?.group(1) ??
        switch (kind) {
          'registerStainedGlass' => 'StainedGlassBlock',
          'registerLegacyStair' || 'registerStair' => 'StairBlock',
          _ => 'Block',
        };
    final flammable = body.contains('.ignitedByLava()');
    final expr = colorExprOf(body);
    final colorName = switch (kind) {
      'registerStainedGlass' => _dyeToMapColor[
          RegExp(r'DyeColor\.(\w+)').firstMatch(body)?.group(1)
      ],
      'registerLegacyStair' || 'registerStair' => resolveField(
          RegExp(r',\s*(\w+)\s*\)').firstMatch(body)?.group(1) ?? '',
        ),
      _ => resolveField(field),
    };
    final topName = resolveTopColor(field);
    if (colorName == null) {
      unparseable.add(field);
      continue;
    }
    final color = colorByName[colorName];
    final top = topName == null ? null : colorByName[topName];
    final sideToken = expr?.logSide == null
        ? null
        : colorNameOfToken(expr!.logSide!);
    final sideName = sideToken == null
        ? null
        : sideToken.startsWith('FIELD:')
        ? resolveField(sideToken.substring(6))
        : sideToken;
    final side = sideName == null ? null : colorByName[sideName];
    out[id] = {
      'field': field,
      'class': className,
      'mapColorId': color?.id ?? -1,
      'mapColorName': colorName,
      'rgb': color == null
          ? null
          : [color.rgb >> 16 & 0xff, color.rgb >> 8 & 0xff, color.rgb & 0xff],
      'sideMapColorName': sideName,
      'sideRgb': side == null
          ? null
          : [side.rgb >> 16 & 0xff, side.rgb >> 8 & 0xff, side.rgb & 0xff],
      'topMapColorId': top?.id ?? color?.id ?? -1,
      'flammable': flammable,
      'fullCubeClass': fullCubeClasses.contains(className),
      'noCollision': body.contains('noCollision()'),
      'noOcclusion': body.contains('noOcclusion()') || kind == 'registerStainedGlass',
      'isPillar': expr?.logSide != null,
    };
  }
  stdout.writeln('blocks with a resolved colour: ${out.length}');
  if (unparseable.isNotEmpty) {
    stdout.writeln('no colour resolved (${unparseable.length}): '
        '${unparseable.take(12).join(', ')}'
        '${unparseable.length > 12 ? ', ...' : ''}');
  }

  File('tool/data/generated_block_colors.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(out),
  );

  // ---- diff against the vendored table ----
  final vendored = jsonDecode(
    File('assets/colors/mapartcraft.colors.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  final vendoredNames = <String>{};
  final vendoredEntries = <({String name, int color, String? axis})>[];
  for (final entry in vendored.entries) {
    final colorIndex = int.parse(entry.key);
    final blocks = (entry.value as Map<String, dynamic>)['blocks']
        as Map<String, dynamic>;
    for (final b in blocks.values) {
      final map = b as Map<String, dynamic>;
      final versions = map['validVersions'] as Map<String, dynamic>;
      String? name;
      String? axis;
      final keys = versions.keys
          .where((k) => !k.startsWith('&'))
          .map((k) => (k, _versionRank(k)))
          .toList()
        ..sort((a, b) => b.$2.compareTo(a.$2));
      for (final k in keys) {
        final v = versions[k.$1];
        if (v is Map && v['NBTName'] is String) {
          name = (v['NBTName'] as String).replaceFirst('minecraft:', '');
          final args = v['NBTArgs'];
          if (args is Map && args['axis'] is String) axis = args['axis'] as String;
          break;
        }
      }
      name ??= (map['displayName'] as String)
          .toLowerCase()
          .replaceAll(' ', '_');
      vendoredNames.add(name);
      vendoredEntries.add((name: name, color: colorIndex, axis: axis));
    }
  }

  // Vendored colour index -> base RGB, for value comparison.
  final vendoredRgb = <int, int>{};
  for (final entry in vendored.entries) {
    final tones = (entry.value as Map<String, dynamic>)['tonesRGB']
        as Map<String, dynamic>;
    final light = (tones['light'] as List).cast<num>();
    vendoredRgb[int.parse(entry.key)] =
        (light[0].toInt() << 16) | (light[1].toInt() << 8) | light[2].toInt();
  }

  stdout.writeln('\n== vendored blocks whose colour disagrees with 26.1.2 ==');
  var disagreements = 0;
  var agreements = 0;
  final missingFromGame = <String>[];
  for (final e in vendoredEntries) {
    final gen = out[e.name] as Map<String, dynamic>?;
    if (gen == null) {
      missingFromGame.add(e.name);
      continue;
    }
    // axis=x/z shows the side colour; axis=y and "no axis" show the default,
    // which for a pillar is the top.
    final useSide = e.axis == 'x' || e.axis == 'z';
    final effective = useSide ? (gen['sideRgb'] ?? gen['rgb']) : gen['rgb'];
    final got = vendoredRgb[e.color];
    final same = effective is List &&
        got != null &&
        (got >> 16 & 0xff) == effective[0] &&
        (got >> 8 & 0xff) == effective[1] &&
        (got & 0xff) == effective[2];
    if (same) {
      agreements++;
    } else {
      disagreements++;
      if (disagreements <= 20) {
        stdout.writeln('  ${e.name} axis=${e.axis ?? '-'}'
            ': vendored #${(got ?? 0).toRadixString(16).padLeft(6, '0')}'
            ' vs game $effective');
      }
    }
  }
  stdout.writeln('  agreements: $agreements, disagreements: $disagreements');
  if (missingFromGame.isNotEmpty) {
    stdout.writeln('  vendored but not in 26.1.2 registry '
        '(${missingFromGame.length}): ${missingFromGame.take(10).join(', ')}'
        '${missingFromGame.length > 10 ? ', ...' : ''}');
  }

  stdout.writeln('\n== staircase cubes in 26.1.2 the vendored table lacks ==');
  final supplement = <Map<String, dynamic>>[];
  for (final e in out.entries) {
    final gen = e.value as Map<String, dynamic>;
    if (!_staircaseCube(e.key, gen)) continue;
    if (vendoredNames.contains(e.key)) continue;
    final since = _since(e.key);
    if (since == '1.20') continue;
    supplement.add({
      'id': e.key,
      'displayName': _displayName(e.key),
      'mapColor': gen['mapColorName'],
      'rgb': gen['rgb'],
      'flammable': gen['flammable'],
      'pillar': gen['isPillar'] == true,
      'since': since,
    });
  }
  supplement.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
  final bySince = <String, int>{};
  for (final b in supplement) {
    final s = b['since'] as String;
    bySince[s] = (bySince[s] ?? 0) + 1;
  }
  stdout.writeln('  ${supplement.length} blocks  $bySince');
  for (final b in supplement.where((b) => b['since'] != '1.20')) {
    stdout.writeln('  ${b['since']}  ${b['id']} -> ${b['mapColor']}');
  }

  final colors = <String, dynamic>{};
  for (final e in colorByName.entries) {
    final rgb = e.value.rgb;
    colors[e.key] = {
      'id': e.value.id,
      'rgb': [rgb >> 16 & 0xff, rgb >> 8 & 0xff, rgb & 0xff],
    };
  }
  final blocks = <String, dynamic>{};
  for (final e in out.entries) {
    final gen = e.value as Map<String, dynamic>;
    blocks[e.key] = {
      'mapColor': gen['mapColorName'],
      'mapColorId': gen['mapColorId'],
      'rgb': gen['rgb'],
      if (gen['sideRgb'] != null) 'sideMapColor': gen['sideMapColorName'],
      if (gen['sideRgb'] != null) 'sideRgb': gen['sideRgb'],
      'flammable': gen['flammable'],
      'pillar': gen['isPillar'],
      'staircaseCube': _staircaseCube(e.key, gen),
    };
  }
  File('assets/colors/block_map_colors.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'source': {
        'game': '26.1.2',
        'clientJarSha1': '4e618f09a0c649dde3fdf829df443ce0b8831e65',
        'classes': [
          'net.minecraft.world.level.material.MapColor',
          'net.minecraft.world.level.block.Blocks',
        ],
        'note':
            'Read out of the game code, not computed from textures. A map '
            'shows the MapColor a block is registered with; the texture '
            'average is a different number and is not what the map shows.',
      },
      'mapColors': colors,
      'blocks': blocks,
    }),
  );
  File('assets/colors/block_supplement.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'note':
          'Full-cube building blocks present in Minecraft 26.1.2 and absent '
          'from the vendored MapartCraft table. Each one maps onto a MapColor '
          'that table already has — none of them adds a colour. `since` is the '
          'first release the block exists in; the palette only offers a block '
          'when the selected version is at least that.',
      'blocks': supplement,
    }),
  );
  stdout.writeln('\nwrote assets/colors/block_map_colors.json '
      '(${blocks.length} blocks, ${colors.length} map colours)');
  stdout.writeln('wrote assets/colors/block_supplement.json '
      '(${supplement.length} blocks)');
}

/// DyeColor.getMapColor() as of 26.1.2. White is SNOW, not WOOL: wool-white and
/// snow-white are different map colours, and stained glass follows the dye.
const _dyeToMapColor = <String, String>{
  'WHITE': 'SNOW',
  'ORANGE': 'COLOR_ORANGE',
  'MAGENTA': 'COLOR_MAGENTA',
  'LIGHT_BLUE': 'COLOR_LIGHT_BLUE',
  'YELLOW': 'COLOR_YELLOW',
  'LIME': 'COLOR_LIGHT_GREEN',
  'PINK': 'COLOR_PINK',
  'GRAY': 'COLOR_GRAY',
  'LIGHT_GRAY': 'COLOR_LIGHT_GRAY',
  'CYAN': 'COLOR_CYAN',
  'PURPLE': 'COLOR_PURPLE',
  'BLUE': 'COLOR_BLUE',
  'BROWN': 'COLOR_BROWN',
  'GREEN': 'COLOR_GREEN',
  'RED': 'COLOR_RED',
  'BLACK': 'COLOR_BLACK',
};

/// A block a staircase can be built out of: a full cube you can place and
/// walk on, not a plant, door, ore or command block.
///
/// Judged from the registration, which is what the game itself says. A
/// constructor-class whitelist was tried first and is wrong: most full cubes
/// are plain `Block`, so the class name does not distinguish a plank from a
/// sapling.
bool _staircaseCube(String id, Map<String, dynamic> gen) {
  if (gen['mapColorId'] == 0 || gen['mapColorId'] == -1) return false;
  if (gen['noCollision'] == true || gen['noOcclusion'] == true) return false;
  if (_excludedId(id)) return false;
  const notSolid = {
    'StairBlock',
    'SlabBlock',
    'FenceBlock',
    'FenceGateBlock',
    'WallBlock',
    'CarpetBlock',
    'DoorBlock',
    'TrapDoorBlock',
    'ButtonBlock',
    'PressurePlateBlock',
    'CandleBlock',
    'SignBlock',
    'WallSignBlock',
    'HangingSignBlock',
    'BannerBlock',
    'BedBlock',
    'ChestBlock',
    'BarrelBlock',
    'LanternBlock',
    'ChainBlock',
    'IronBarsBlock',
    'PaneBlock',
    'ScaffoldingBlock',
    'LadderBlock',
    'VineBlock',
    'TorchBlock',
    'FlowerBlock',
    'SaplingBlock',
    'BushBlock',
    'CoralFanBlock',
    'CoralWallFanBlock',
    'CoralPlantBlock',
    'BaseCoralPlantBlock',
    'SeaPickleBlock',
    'TurtleEggBlock',
    'SnifferEggBlock',
    'DragonEggBlock',
    'EndRodBlock',
    'LightningRodBlock',
    'RodBlock',
    'AmethystClusterBlock',
    'PointedDripstoneBlock',
    'SculkVeinBlock',
    'GlowLichenBlock',
    'HangingRootsBlock',
    'SporeBlossomBlock',
    'AzaleaBlock',
    'BigDripleafBlock',
    'SmallDripleafBlock',
    'PitcherCropBlock',
    'CropBlock',
    'StemBlock',
    'AttachedStemBlock',
    'CocoaBlock',
    'SweetBerryBushBlock',
    'CaveVinesBlock',
    'WeepingVinesBlock',
    'TwistingVinesBlock',
    'KelpBlock',
    'SeagrassBlock',
    'TallSeagrassBlock',
    'SugarCaneBlock',
    'BambooStalkBlock',
    'CactusBlock',
    'ChorusPlantBlock',
    'ChorusFlowerBlock',
    'NetherPortalBlock',
    'EndPortalBlock',
    'EndGatewayBlock',
    'PistonBaseBlock',
    'PistonHeadBlock',
    'MovingPistonBlock',
    'ShulkerBoxBlock',
    'HopperBlock',
    'AnvilBlock',
    'BrewingStandBlock',
    'CauldronBlock',
    'ComposterBlock',
    'LecternBlock',
    'EnchantingTableBlock',
    'GrindstoneBlock',
    'StonecutterBlock',
    'BellBlock',
    'ConduitBlock',
    'BeaconBlock',
    'SpawnerBlock',
    'TrialSpawnerBlock',
    'VaultBlock',
    'DecoratedPotBlock',
    'FlowerPotBlock',
    'SkullBlock',
    'HeadBlock',
    'CampfireBlock',
    'Lantern',
    'Chain',
    'PowderSnowBlock',
    'Scaffolding',
    'LightBlock',
    'BarrierBlock',
    'StructureBlock',
    'JigsawBlock',
    'CommandBlock',
    'TestBlock',
    'TestInstanceBlock',
    'CrafterBlock',
    'CopperGrateBlock',
    'CopperBulbBlock',
  };
  final className = gen['class'] as String;
  if (notSolid.contains(className)) return false;
  return true;
}

const _badSuffixes = <String>[
  '_wall_hanging_sign',
  '_hanging_sign',
  '_wall_sign',
  '_sign',
  '_wall_banner',
  '_banner',
  '_wall_fan',
  '_coral_fan',
  '_fence_gate',
  '_fence',
  '_pressure_plate',
  '_button',
  '_trapdoor',
  '_door',
  '_slab',
  '_stairs',
  '_wall',
  '_carpet',
  '_candle',
  '_sapling',
  '_propagule',
  '_torch',
  '_lantern',
  '_chain',
  '_bars',
  '_rod',
  '_rail',
  '_ladder',
  '_vine',
  '_head',
  '_skull',
  '_pot',
  '_shelf',
  '_grate',
  '_bulb',
  '_chest',
  '_statue',
  '_shulker_box',
  '_bed',
  '_egg',
];

bool _excludedId(String id) {
  if (id.endsWith('_ore') || id.contains('_ore_')) return true;
  if (id.startsWith('infested_')) return true;
  if (id.startsWith('potted_')) return true;
  if (id.startsWith('waxed_') && id.contains('grate')) return true;
  for (final suffix in _badSuffixes) {
    if (id.endsWith(suffix)) return true;
  }
  const exact = {
    'air',
    'water',
    'lava',
    'fire',
    'soul_fire',
    'campfire',
    'soul_campfire',
    'cactus',
    'sugar_cane',
    'bamboo',
    'chorus_plant',
    'chorus_flower',
    'cobweb',
    'scaffolding',
    'powder_snow',
    'vine',
    'glow_lichen',
    'sculk_vein',
    'pointed_dripstone',
    'amethyst_cluster',
    'small_amethyst_bud',
    'medium_amethyst_bud',
    'large_amethyst_bud',
    'spore_blossom',
    'hanging_roots',
    'frogspawn',
    'dragon_egg',
    'conduit',
    'beacon',
    'end_rod',
    'lightning_rod',
    'chain',
    'iron_bars',
    'farmland',
    'dirt_path',
    'grass_path',
    'reinforced_deepslate',
    'bedrock',
    'barrier',
    'light',
    'structure_block',
    'structure_void',
    'jigsaw',
    'command_block',
    'chain_command_block',
    'repeating_command_block',
    'spawner',
    'trial_spawner',
    'vault',
    'ominous_vault',
    'crafter',
    'piston',
    'sticky_piston',
    'piston_head',
    'moving_piston',
    'end_portal',
    'end_portal_frame',
    'end_gateway',
    'nether_portal',
    'chest',
    'trapped_chest',
    'ender_chest',
    'barrel',
    'hopper',
    'composter',
    'lectern',
    'enchanting_table',
    'brewing_stand',
    'cauldron',
    'anvil',
    'chipped_anvil',
    'damaged_anvil',
    'grindstone',
    'stonecutter',
    'bell',
    'decorated_pot',
    'flower_pot',
    'cake',
    'candle_cake',
    'turtle_egg',
    'sniffer_egg',
    'heavy_core',
    'test_block',
    'test_instance_block',
    'budding_amethyst',
    'sculk_shrieker',
    'sculk_sensor',
    'calibrated_sculk_sensor',
    'sculk_catalyst',
    'respawn_anchor',
    'lodestone',
    'crying_obsidian',
    'ancient_debris',
  };
  return exact.contains(id);
}

/// First release this block can be placed in.
///
/// Anything not recognised here already existed in 1.20 — the vendored table
/// simply never listed it. New content is named explicitly so a 1.21 schematic
/// cannot contain a block from a later drop.
String _since(String id) {
  if (id.contains('pale_oak') ||
      id.contains('pale_moss') ||
      id.contains('resin') ||
      id.contains('creaking') ||
      id.contains('eyeblossom')) {
    return '1.21.4';
  }
  if (id == 'polished_tuff' ||
      id == 'tuff_bricks' ||
      id == 'chiseled_tuff' ||
      id == 'chiseled_tuff_bricks' ||
      id.startsWith('waxed_') &&
          (id.contains('copper_bulb') || id.contains('chiseled_copper'))) {
    return '1.21';
  }
  if (id.contains('copper_golem') ||
      id.contains('copper_chest') ||
      id == 'golden_dandelion') {
    return '26.1';
  }
  return '1.20';
}

String _displayName(String id) => id
    .split('_')
    .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');

int _versionRank(String v) {
  final parts = v.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  while (parts.length < 3) {
    parts.add(0);
  }
  return parts[0] * 1000000 + parts[1] * 1000 + parts[2];
}
