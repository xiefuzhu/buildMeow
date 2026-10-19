import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:mapart_core/mapart_core.dart';
import 'package:test/test.dart';

/// A solid RGBA texture.
Uint8List _solidTexture(int r, int g, int b, {int size = 4, int a = 255}) {
  final image = img.Image(width: size, height: size, numChannels: 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      image.setPixelRgba(x, y, r, g, b, a);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

/// Half black, half white, so the two ways of averaging disagree: 128 the naive
/// way, 188 in linear light.

/// A grey RGBA texture.
Uint8List _greyTexture(List<int> values) {
  final image = img.Image(width: values.length, height: 1, numChannels: 4);
  for (var x = 0; x < values.length; x++) {
    image.setPixelRgba(x, 0, values[x], values[x], values[x], 255);
  }
  return Uint8List.fromList(img.encodePng(image));
}

/// The model files every synthetic block leans on, so the parent chain is
/// exercised rather than assumed.
Map<String, String> _baseModels() => <String, String>{
  'assets/minecraft/models/block/cube.json': '''
    {"parent": "block/block", "elements": [{"from": [0,0,0], "to": [16,16,16],
      "faces": {
        "down": {"texture": "#down", "cullface": "down"},
        "up": {"texture": "#up", "cullface": "up"},
        "north": {"texture": "#north", "cullface": "north"},
        "south": {"texture": "#south", "cullface": "south"},
        "west": {"texture": "#west", "cullface": "west"},
        "east": {"texture": "#east", "cullface": "east"}}}]}''',
  'assets/minecraft/models/block/block.json': '{"gui_light": "side"}',
  'assets/minecraft/models/block/cube_all.json': '''
    {"parent": "block/cube", "textures": {
      "particle": "#all", "down": "#all", "up": "#all",
      "north": "#all", "east": "#all", "south": "#all", "west": "#all"}}''',
  'assets/minecraft/models/block/cube_column.json': '''
    {"parent": "block/cube", "textures": {
      "particle": "#side", "down": "#end", "up": "#end",
      "north": "#side", "east": "#side", "south": "#side", "west": "#side"}}''',
};

/// Builds a jar in memory. [blocks] maps a block id to a blockstate JSON and
/// the extra model files and textures it needs.
Uint8List _jar({
  required Map<String, String> blocks,
  Map<String, String> models = const <String, String>{},
  Map<String, Uint8List> textures = const <String, Uint8List>{},
  Set<String> animatedTextures = const <String>{},
}) {
  final archive = Archive();
  void add(String path, String content) =>
      archive.addFile(ArchiveFile.string(path, content));
  void addBytes(String path, Uint8List bytes) =>
      archive.addFile(ArchiveFile.bytes(path, bytes));

  _baseModels().forEach(add);
  blocks.forEach(
    (id, state) => add('assets/minecraft/blockstates/$id.json', state),
  );
  models.forEach(
    (path, json) => add('assets/minecraft/models/block/$path.json', json),
  );
  textures.forEach(
    (path, bytes) => addBytes('assets/minecraft/textures/block/$path.png', bytes),
  );
  for (final path in animatedTextures) {
    add(
      'assets/minecraft/textures/block/$path.png.mcmeta',
      '{"animation": {"frametime": 2}}',
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// A blockstate with a single plain variant pointing at `block/<id>`.
String _plainState(String id) =>
    '{"variants": {"": {"model": "minecraft:block/$id"}}}';

void main() {
  group('average colour', () {
    test('is taken in linear light, so black and white give 188 not 128', () {
      final rgba = <int>[
        0, 0, 0, 255,
        255, 255, 255, 255,
      ];
      final average = averageTexture(Uint8List.fromList(rgba), 2, 1)!;
      // Averaging the 8-bit values would give 127 or 128. Linear light gives
      // 188, because half the light is half the light.
      expect(average.srgb.r, 188);
      expect(average.srgb.g, 188);
      expect(average.srgb.b, 188);
      expect(average.linear.r, closeTo(0.5, 1e-9));
    });

    test('skips fully transparent pixels', () {
      final rgba = <int>[
        255, 0, 0, 255,
        0, 0, 255, 0, // transparent, must not drag the average
      ];
      final average = averageTexture(Uint8List.fromList(rgba), 2, 1)!;
      expect(average.srgb.r, 255);
      expect(average.srgb.b, 0);
      expect(average.opaquePixels, 1);
    });

    test('a fully transparent texture has no colour', () {
      final rgba = Uint8List.fromList(<int>[0, 0, 0, 0, 0, 0, 0, 0]);
      expect(averageTexture(rgba, 2, 1), isNull);
    });

    test('noisiness is the luminance deviation, per the spec example', () {
      // 120, 125, 130, 125 -> mean 125, deviation 3.5.
      final flat = averageTexture(
        Uint8List.fromList(<int>[
          120, 120, 120, 255,
          125, 125, 125, 255,
          130, 130, 130, 255,
          125, 125, 125, 255,
        ]),
        4,
        1,
      )!;
      expect(flat.noisiness, closeTo(3.5, 0.05));

      // 60, 60, 200, 200 -> mean 130, deviation 70. Nearly the same *naive*
      // mean as the texture above, seven times the texture.
      final speckled = averageTexture(
        Uint8List.fromList(<int>[
          60, 60, 60, 255,
          60, 60, 60, 255,
          200, 200, 200, 255,
          200, 200, 200, 255,
        ]),
        4,
        1,
      )!;
      expect(speckled.noisiness, closeTo(70, 0.05));

      // The naive means agree to within 5, which is why noisiness has to be
      // measured separately rather than inferred from the colour.
      expect(speckled.noisiness / flat.noisiness, greaterThan(15));
      // The linear-light average does not agree, and should not: half the
      // pixels being dark does not make the texture dark.
      expect(speckled.srgb.r, greaterThan(flat.srgb.r));
    });

    test('a greyscale PNG keeps all three channels', () {
      // `image` gives a one-channel image back for a greyscale PNG and leaves
      // `g` and `b` at zero, which averaged `stone` to (126, 0, 0).
      final grey = img.Image.fromBytes(
        width: 4,
        height: 4,
        bytes: Uint8List.fromList(List<int>.filled(16, 126)).buffer,
        numChannels: 1,
      );
      final jar = _jar(
        blocks: <String, String>{'grey': _plainState('grey')},
        models: <String, String>{
          'grey': '{"parent": "block/cube_all", "textures": {"all": "block/grey"}}',
        },
        textures: <String, Uint8List>{
          'grey': Uint8List.fromList(img.encodePng(grey)),
        },
      );
      final palette = extractTexturePalette(jar, source: 'test.jar');
      final average = palette.accepted.single.average!;
      expect(average.srgb.r, 126);
      expect(average.srgb.g, 126);
      expect(average.srgb.b, 126);
    });

    test('partial alpha is detected', () {
      expect(
        hasPartialAlpha(Uint8List.fromList(<int>[0, 0, 0, 0, 0, 0, 0, 255])),
        isFalse,
      );
      expect(
        hasPartialAlpha(Uint8List.fromList(<int>[0, 0, 0, 128, 0, 0, 0, 255])),
        isTrue,
      );
    });

    test('the sRGB curve round-trips', () {
      for (var v = 0; v <= 255; v++) {
        final back = linearToSrgb(srgbToLinear(v / 255)) * 255;
        expect(back, closeTo(v, 0.001), reason: '$v');
      }
    });
  });

  group('face brightness', () {
    test('matches the game constants', () {
      expect(BlockFace.up.brightness, 1.0);
      expect(BlockFace.down.brightness, 0.5);
      expect(BlockFace.north.brightness, 0.8);
      expect(BlockFace.south.brightness, 0.8);
      expect(BlockFace.east.brightness, 0.6);
      expect(BlockFace.west.brightness, 0.6);
    });

    test('is off by default and darkens the colour when switched on', () {
      final jar = _jar(
        blocks: <String, String>{'plain': _plainState('plain')},
        models: <String, String>{
          'plain': '{"parent": "block/cube_all", "textures": {"all": "block/plain"}}',
        },
        textures: <String, Uint8List>{'plain': _solidTexture(200, 200, 200)},
      );
      final palette = extractTexturePalette(jar, source: 'test.jar');

      final plain = selectPaletteBlocks(palette, const TexturePaletteOptions());
      expect(plain.single.color.r, 200);

      final shaded = selectPaletteBlocks(
        palette,
        const TexturePaletteOptions(applyFaceBrightness: true),
      );
      // Top face is 1.0, so a top-face palette is unchanged; that is the point
      // of leaving it off by default.
      expect(shaded.single.color.r, 200);
    });

    test('a side face really is darkened', () {
      final jar = _jar(
        blocks: <String, String>{'plain': _plainState('plain')},
        models: <String, String>{
          'plain': '{"parent": "block/cube_all", "textures": {"all": "block/plain"}}',
        },
        textures: <String, Uint8List>{'plain': _solidTexture(255, 255, 255)},
      );
      final palette = extractTexturePalette(
        jar,
        source: 'test.jar',
        face: BlockFace.east,
      );
      final shaded = selectPaletteBlocks(
        palette,
        const TexturePaletteOptions(applyFaceBrightness: true),
      );
      // 255 in linear light is 1.0; times the east face's 0.6 is 0.6, which
      // comes back as 203 in sRGB — the same factor the game applies.
      expect(shaded.single.color.r, closeTo(203, 1));
    });
  });

  group('model parsing', () {
    test('follows the parent chain and the child overrides the parent', () {
      final jar = _jar(
        blocks: <String, String>{'log': _plainState('log')},
        models: <String, String>{
          // cube_column gives the sides `#side` and the ends `#end`.
          'log': '{"parent": "minecraft:block/cube_column", "textures": {'
              '"end": "minecraft:block/log_top", "side": "minecraft:block/log_side"}}',
        },
        textures: <String, Uint8List>{
          'log_top': _solidTexture(10, 20, 30),
          'log_side': _solidTexture(200, 100, 50),
        },
      );

      final top = extractTexturePalette(jar, source: 'test.jar');
      expect(top.accepted.single.texture, 'block/log_top');
      expect(top.accepted.single.average!.srgb.r, 10);

      final side = extractTexturePalette(
        jar,
        source: 'test.jar',
        face: BlockFace.north,
      );
      expect(side.accepted.single.texture, 'block/log_side');
      expect(side.accepted.single.average!.srgb.r, 200);
    });

    test('a face texture may be an object, and force_translucent is honoured', () {
      final jar = _jar(
        blocks: <String, String>{'glass': _plainState('glass')},
        models: <String, String>{
          'glass': '{"parent": "block/cube_all", "textures": {'
              '"all": {"sprite": "block/glass", "force_translucent": true}}}',
        },
        textures: <String, Uint8List>{'glass': _solidTexture(180, 220, 240)},
      );
      final palette = extractTexturePalette(jar, source: 'test.jar');
      expect(palette.entries.single.excluded, ExclusionReason.translucent);
      expect(palette.accepted, isEmpty);
    });

    test('a namespaced reference resolves', () {
      final jar = _jar(
        blocks: <String, String>{'plain': _plainState('plain')},
        models: <String, String>{
          'plain': '{"parent": "minecraft:block/cube_all", '
              '"textures": {"all": "minecraft:block/plain"}}',
        },
        textures: <String, Uint8List>{'plain': _solidTexture(1, 2, 3)},
      );
      final palette = extractTexturePalette(jar, source: 'test.jar');
      expect(palette.accepted.single.texture, 'block/plain');
    });

    test('a tintindex marks a biome-tinted face', () {
      final jar = _jar(
        blocks: <String, String>{'grass': _plainState('grass')},
        models: <String, String>{
          'grass': '{"parent": "block/cube_all", "elements": [{"from": [0,0,0], '
              '"to": [16,16,16], "faces": {'
              '"down": {"texture": "#all"}, '
              '"up": {"texture": "#all", "tintindex": 0}, '
              '"north": {"texture": "#all"}, "south": {"texture": "#all"}, '
              '"west": {"texture": "#all"}, "east": {"texture": "#all"}}}], '
              '"textures": {"all": "block/grass"}}',
        },
        textures: <String, Uint8List>{'grass': _solidTexture(100, 160, 60)},
      );
      final palette = extractTexturePalette(jar, source: 'test.jar');
      expect(palette.entries.single.excluded, ExclusionReason.biomeTinted);
    });

    test('an animated texture is recognised by the .mcmeta beside it', () {
      final jar = _jar(
        blocks: <String, String>{'lavaish': _plainState('lavaish')},
        models: <String, String>{
          'lavaish': '{"parent": "block/cube_all", "textures": {"all": "block/lavaish"}}',
        },
        textures: <String, Uint8List>{'lavaish': _solidTexture(240, 120, 20)},
        animatedTextures: <String>{'lavaish'},
      );
      final palette = extractTexturePalette(jar, source: 'test.jar');
      expect(palette.entries.single.excluded, ExclusionReason.animated);
    });
  });

  group('cleaning rules', () {
    Uint8List paletteJar() => _jar(
      blocks: <String, String>{
        'solid': _plainState('solid'),
        'partial': _plainState('partial'),
        'translucent': _plainState('translucent'),
        'directional': '{"variants": {"facing=north": {"model": "minecraft:block/solid"}, '
            '"facing=south": {"model": "minecraft:block/solid"}}}',
        'multipart': '{"multipart": [{"apply": {"model": "minecraft:block/solid"}}]}',
        'tiny': _plainState('tiny'),
        'overlaid': _plainState('overlaid'),
        'fronted': _plainState('fronted'),
        'sand': _plainState('sand'),
        'glowstone': _plainState('glowstone'),
      },
      models: <String, String>{
        'solid': '{"parent": "block/cube_all", "textures": {"all": "block/solid"}}',
        'partial': '{"parent": "block/cube_all", "textures": {"all": "block/partial"}}',
        'translucent': '{"parent": "block/cube_all", "textures": {"all": "block/translucent"}}',
        'tiny': '{"parent": "block/block", "elements": [{"from": [0,0,0], "to": [16,8,16], '
            '"faces": {"up": {"texture": "block/solid"}}}], '
            '"textures": {"all": "block/solid"}}',
        // Two elements: an overlay drawn over a full cube.
        'overlaid': '{"parent": "block/cube_all", "textures": {"all": "block/solid"}, '
            '"elements": [{"from": [0,0,0], "to": [16,16,16], "faces": {'
            '"down": {"texture": "#all"}, "up": {"texture": "#all"}, '
            '"north": {"texture": "#all"}, "south": {"texture": "#all"}, '
            '"west": {"texture": "#all"}, "east": {"texture": "#all"}}}, '
            '{"from": [0,0,0], "to": [16,16,16], "faces": {"up": {"texture": "#all"}}}]}',
        // A different texture on one side: a distinct front.
        'fronted': '{"parent": "block/cube", "textures": {"down": "block/solid", '
            '"up": "block/solid", "north": "block/solid", "south": "block/solid", '
            '"west": "block/solid", "east": "block/other"}}',
        'sand': '{"parent": "block/cube_all", "textures": {"all": "block/sand"}}',
        'glowstone': '{"parent": "block/cube_all", "textures": {"all": "block/glowstone"}}',
      },
      textures: <String, Uint8List>{
        'solid': _solidTexture(100, 100, 100),
        'partial': _solidTexture(100, 100, 100, a: 128),
        'translucent': _solidTexture(100, 100, 100, a: 0),
        'other': _solidTexture(100, 100, 100),
        'sand': _solidTexture(219, 208, 164),
        // Speckled, so the noisiness filter has something to bite on.
        'glowstone': _greyTexture(<int>[100, 160, 220, 80, 200, 60, 140, 180]),
      },
    );

    test('rejects by the reason the spec names', () {
      final palette = extractTexturePalette(paletteJar(), source: 'test.jar');
      final reasons = <String, ExclusionReason?>{
        for (final entry in palette.entries) entry.blockId: entry.excluded,
      };
      expect(reasons['solid'], isNull);
      expect(reasons['partial'], ExclusionReason.translucent);
      expect(reasons['translucent'], ExclusionReason.translucent);
      expect(reasons['directional'], ExclusionReason.patterned);
      expect(reasons['multipart'], ExclusionReason.multipart);
      expect(reasons['tiny'], ExclusionReason.notAFullCube);
      expect(reasons['overlaid'], ExclusionReason.patterned);
      expect(reasons['fronted'], ExclusionReason.patterned);
      // Flagged, not dropped: the average colour is there, the user just has
      // to switch the category on.
      expect(reasons['sand'], ExclusionReason.falling);
      expect(reasons['glowstone'], ExclusionReason.emissive);
      expect(palette.entryFor('minecraft:sand')!.average, isNotNull);
    });

    test('the noisiness threshold drops the speckled block', () {
      final palette = extractTexturePalette(paletteJar(), source: 'test.jar');
      final kept = selectPaletteBlocks(
        palette,
        const TexturePaletteOptions(maxNoisiness: 20),
      );
      expect(kept.map((b) => b.blockId), contains('solid'));
      expect(kept.map((b) => b.blockId), isNot(contains('glowstone')));
    });

    test('falling and emissive blocks are out by default and switchable on', () {
      final palette = extractTexturePalette(paletteJar(), source: 'test.jar');
      final defaults = selectPaletteBlocks(
        palette,
        const TexturePaletteOptions(maxNoisiness: 100),
      );
      expect(defaults.map((b) => b.blockId), isNot(contains('sand')));
      expect(defaults.map((b) => b.blockId), isNot(contains('glowstone')));

      final included = selectPaletteBlocks(
        palette,
        const TexturePaletteOptions(
          maxNoisiness: 100,
          includeFalling: true,
          includeEmissive: true,
        ),
      );
      expect(included.map((b) => b.blockId), contains('sand'));
      expect(included.map((b) => b.blockId), contains('glowstone'));
    });

    test('a rejected block can be switched back on by hand', () {
      final palette = extractTexturePalette(paletteJar(), source: 'test.jar');
      final forced = selectPaletteBlocks(
        palette,
        const TexturePaletteOptions(
          maxNoisiness: 100,
          dedupeDistance: 0,
          forceInclude: <String>{'minecraft:fronted'},
        ),
      );
      expect(forced.map((b) => b.blockId), contains('fronted'));
    });

    test('a block can be switched off by hand', () {
      final palette = extractTexturePalette(paletteJar(), source: 'test.jar');
      final kept = selectPaletteBlocks(
        palette,
        const TexturePaletteOptions(
          forceExclude: <String>{'minecraft:solid'},
        ),
      );
      expect(kept.map((b) => b.blockId), isNot(contains('solid')));
    });

    test('near-identical colours are deduped, keeping the flatter one', () {
      final jar = _jar(
        blocks: <String, String>{
          'flat': _plainState('flat'),
          'speckled': _plainState('speckled'),
        },
        models: <String, String>{
          'flat': '{"parent": "block/cube_all", "textures": {"all": "block/flat"}}',
          'speckled': '{"parent": "block/cube_all", "textures": {"all": "block/speckled"}}',
        },
        textures: <String, Uint8List>{
          'flat': _greyTexture(<int>[125, 125, 125, 125]),
          'speckled': _greyTexture(<int>[124, 126, 124, 126]),
        },
      );
      final kept = selectPaletteBlocks(
        extractTexturePalette(jar, source: 'test.jar'),
        const TexturePaletteOptions(dedupeDistance: 4),
      );
      expect(kept, hasLength(1));
      expect(kept.single.blockId, 'flat');

      // With dedupe off, both survive.
      final both = selectPaletteBlocks(
        extractTexturePalette(jar, source: 'test.jar'),
        const TexturePaletteOptions(dedupeDistance: 0),
      );
      expect(both, hasLength(2));
    });
  });

  group('the real jar', () {
    // The extraction is written against a real client jar, so the numbers below
    // were read off one rather than guessed. Skipped when the machine has no
    // Minecraft installed, which is also why the app cannot rely on one.
    final jarFile = File(
      r'C:\Users\xiefuzhu\AppData\Roaming\.minecraft\versions\26.1.2\26.1.2.jar',
    );

    test('extracts a usable palette and reports how long it took', () {
      if (!jarFile.existsSync()) {
        markTestSkipped('no Minecraft jar on this machine');
        return;
      }
      final bytes = jarFile.readAsBytesSync();
      final watch = Stopwatch()..start();
      final palette = extractTexturePalette(bytes, source: jarFile.path);
      watch.stop();

      final counts = palette.exclusionCounts;
      printOnFailure('reasons: $counts');
      // Every blockstate is accounted for, one way or the other.
      expect(
        palette.entries.length,
        greaterThan(1000),
        reason: 'a client jar has ~1170 blockstates',
      );
      expect(
        palette.accepted.length,
        greaterThan(300),
        reason: 'the measured count is ~361 full cubes',
      );

      final kept = selectPaletteBlocks(palette, const TexturePaletteOptions());
      printOnFailure('kept after thresholds: ${kept.length}');
      // Measured at 136 distinct colours out of ~304 averaged cubes, against 60
      // in map-colour mode. The rest collapse into each other under the dedupe
      // distance, which is the point of the distance.
      expect(kept.length, greaterThan(100));

      // Whatever the machine, it has to be quick enough to do once on a
      // background isolate and cache. Measured at ~1.4 s here.
      printOnFailure('extraction took ${watch.elapsedMilliseconds} ms');
      expect(watch.elapsedMilliseconds, lessThan(20000));
    });

    test('finds the blocks the rules are meant to keep and drop', () {
      if (!jarFile.existsSync()) {
        markTestSkipped('no Minecraft jar on this machine');
        return;
      }
      final palette = extractTexturePalette(
        jarFile.readAsBytesSync(),
        source: 'real.jar',
      );

      // Kept, and reading the face the spec asks for.
      TexturePaletteEntry byId(String blockId) => palette.entries
          .firstWhere((e) => e.blockId == blockId, orElse: () => throw StateError('no $blockId'));

      final planks = byId('oak_planks');
      expect(planks.excluded, isNull);
      expect(planks.texture, 'block/oak_planks');
      expect(planks.average!.srgb.r, closeTo(165, 6));

      final log = byId('oak_log');
      expect(log.texture, 'block/oak_log_top', reason: 'the top of a log is its end grain');
      expect(log.state.toBlockStateString(), 'minecraft:oak_log[axis=y]');

      // The ordinary building blocks have to survive, or the cleaning rules are
      // too aggressive to be useful.
      for (final id in <String>[
        'stone',
        'white_wool',
        'black_concrete',
        'orange_terracotta',
        'oak_planks',
        'quartz_block',
        'sandstone',
        'bricks',
        'deepslate',
        'netherrack',
      ]) {
        expect(byId(id).excluded, isNull, reason: '$id should be usable');
      }

      // Dropped, and for the right reason.
      expect(
        byId('grass_block').excluded,
        ExclusionReason.patterned,
        reason: 'grass block is a cube with a tinted overlay',
      );
      expect(byId('glass').excluded, ExclusionReason.translucent);
      expect(byId('ice').excluded, ExclusionReason.translucent);
      expect(byId('oak_leaves').excluded, ExclusionReason.biomeTinted);
      expect(
        byId('furnace').excluded,
        ExclusionReason.patterned,
        reason: 'a furnace is placed facing a direction',
      );
      expect(
        byId('white_glazed_terracotta').excluded,
        ExclusionReason.patterned,
      );
      expect(byId('sand').excluded, ExclusionReason.falling);
      expect(byId('gravel').excluded, ExclusionReason.falling);
      expect(byId('glowstone').excluded, ExclusionReason.emissive);
    });
  });
}
