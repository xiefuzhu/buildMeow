/// Pure-Dart core for the "建喵!" Minecraft mapart blueprint generator.
///
/// Nothing here depends on Flutter, so the whole pipeline can be exercised
/// with `dart test`.
///
/// The pieces, in pipeline order:
///
/// 1. [ColorTable] — the vendored MapartCraft table of 61 base map colours,
///    their four shades, and candidate blocks. See `assets/colors/NOTICE.md`
///    for provenance and the shade arithmetic it is checked against.
/// 2. [VersionTable] — Minecraft release -> `DataVersion` and build limits.
/// 3. [Palette] — the blocks staircase mapart may build with: either one
///    representative full solid cube per usable base colour, or every candidate
///    block, so the user can pick what each colour is made of.
/// 4. [fitToGrid] — Lanczos resample onto the map pixel grid.
/// 5. [quantize] — match every pixel to a (base colour, shade) pair.
/// 6. [solveHeights] — turn the chosen shades into a staircase, globally.
/// 7. [renderMap] — recompute the map colours from the heights, which is the
///    check that steps 5 and 6 agree.
///
/// [ShadeTier] documents the height/shade rule the whole thing rests on.
library;

export 'src/art_kind.dart';
export 'src/build_summary.dart';
export 'src/production_palette.dart';

export 'src/block_colours.dart';
export 'src/block_names.dart';
export 'src/block_state_ref.dart';
export 'src/color_table.dart';
export 'src/height_map.dart';
export 'src/lab.dart';
export 'src/lanczos.dart';
export 'src/map_plan.dart';
export 'src/map_renderer.dart';
export 'src/materials.dart';
export 'src/nbt/nbt_reader.dart';
export 'src/nbt/nbt_tag.dart';
export 'src/nbt/nbt_writer.dart';
export 'src/palette.dart';
export 'src/quantize.dart';
export 'src/resample.dart';
export 'src/rgb.dart';
export 'src/rgba_image.dart';
export 'src/shade_tier.dart';
export 'src/structure/bit_array.dart';
export 'src/structure/litematica.dart';
export 'src/structure/sponge_schematic.dart';
export 'src/structure/structure.dart';
export 'src/texture/block_face.dart';
export 'src/texture/texture_palette.dart';
export 'src/texture/texture_palette_json.dart';
export 'src/version_table.dart';
