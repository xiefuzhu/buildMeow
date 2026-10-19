# Texture palette notes

What the "texture average" palette source is, what was verified against a real
game jar rather than assumed, and what is still unverified.

The other palette source is the vendored map colour table: 61 base colours and
180 reachable staircase shades, which is the game's ceiling. This source does not
use that table at all. It reads the block textures out of the user's own
Minecraft jar, averages each one, and matches against the averages — so the
palette is as large as the game's block list, and the build has no height
staircase: every block sits at one level.

Nothing is bundled with the app. The jar is the user's own game file.

## What was verified, and how

Everything below was read out of a real client jar
(`26.1.2.jar`, 30675 entries: 1171 blockstates, 2393 block models, 1112 block
textures, 102 of them animated). The details that are easy to get wrong:

- A blockstate has either `variants` or `multipart`. 1074 have variants, 96 are
  multipart (fences, walls, shelves). A multipart block has no single model, so
  it has no single face to read.
- A variant is either one object or a list of objects, and may carry an `x`/`y`
  model rotation. The rotation is *not* applied: it is cosmetic, and applying it
  would make the answer depend on which of several equivalent variants the JSON
  happened to list first.
- `parent` chains go through `block/cube`, `block/cube_all`, `block/cube_column`
  and friends. **The child's `textures` override the parent's, and the child's
  `elements` override the parent's too** — walking child-to-root and letting the
  root win is a bug that silently makes every overlaid model look like a plain
  cube. It is the reason `grass_block` and `slime_block` have to be caught by
  the element count.
- A face texture, and a `textures` map value, may be either a string or an
  object: `{"sprite": "block/x", "force_translucent": true}`. 163 of the latter
  in this jar, all on redstone dust and similar. Reading only strings throws.
- References may carry a namespace (`minecraft:block/oak_log`). It has to be
  stripped before building a path.
- `image` reports alpha **0** for a PNG that has no alpha channel at all, so
  trusting `pixel.a` without checking `numChannels` makes every opaque texture
  look fully transparent.
- `image` returns a greyscale PNG as a **one-channel** image whose pixel
  accessor puts the grey in `r` and leaves `g` and `b` at zero. Left alone that
  averaged `stone` to `(126, 0, 0)`. The grey is replicated by hand;
  `Image.convert(numChannels: 4)` was tried first and mangles indexed PNGs —
  `lime_concrete` came out black.
- An animated texture is a `.png.mcmeta` file *beside* the PNG, not a field in
  it.
- A `tintindex` on a face means the game paints it with a biome or foliage
  colour instead of the texture as authored. `grass_block`'s top face has it.

### Face brightness

The game multiplies each face's brightness by a fixed factor: up 1.0, north and
south 0.8, east and west 0.6, down 0.5. Verified against a mod that removes the
shading and describes the constants, and consistent with the vanilla per-face
shade table.

It is off by default, because the palette is built from one face and used on the
same face, so no correction is needed. It is there for the case that needs it: a
palette built from top faces and used on a *wall*, where the game will shade
every pixel as a side and the wall would come out too bright.

## The averaging

Averaged in **linear light**, then converted back to sRGB. The transfer curve is
not a multiply, so the two disagree in a way that shows: black and white average
to 128 the naive way and to **188** the correct way. The test asserts the 188.

Noisiness is the population standard deviation of Rec.709 luminance over the
counted pixels, in 0-255 sRGB units. The spec's worked example is asserted
directly: `120,125,130,125` averages 125 with a deviation of 3.5, and
`60,60,200,200` averages 130 with a deviation of 70. The two colours are nearly
the same and the textures are not, which is why noisiness is measured separately
rather than inferred from the average.

Fully transparent pixels are skipped. A texture that is entirely transparent has
no colour and is dropped.

## Cleaning

Decided from the jar's own data while extracting:

| reason | what it catches | count in `26.1.2.jar` |
| --- | --- | --- |
| `notAFullCube` | buttons, doors, plants, saplings | 319 |
| `multipart` | fences, walls, shelves | 96 |
| `noGeometry` | signs, air | 160 |
| `patterned` | glazed terracotta, furnaces, pistons, crafting tables, grass block | 226 |
| `translucent` | glass, ice, copper grates, fully transparent | 20 |
| `biomeTinted` | leaves, grass tops | 9 |
| `animated` | azalea leaves, command blocks, sculk | 8 |
| `falling` | sand, gravel, concrete powder | 21 |
| `emissive` | glowstone, magma, froglights | 7 |

`patterned` is decided structurally rather than from a list of names, three ways:
the blockstate has a `facing` property; or the four side faces do not resolve to
one texture (a crafting table has a distinct front); or a face carries a UV
`rotation` (how glazed terracotta makes a pattern out of one texture). The side
check has to resolve `#ref`s through the texture map first — `cube_all` gives
every side a different `#name` that all resolve to the same texture, so
comparing the raw references rejects every plain cube in the game.

`falling` and `emissive` are the exception: gravity and light emission are
behaviour, not assets, so they cannot be read out of the jar. They are curated
lists in `texture_palette.dart`, deliberately short, and flagged rather than
dropped — the colour is real, the user just has to say they want it.

Every rejected block keeps its average colour where one could be reached, so the
UI can list it with its reason and switch it back on by hand. Only blocks with
no reachable texture at all cannot be re-enabled.

## Measured

Against `26.1.2.jar`, top face, on this machine:

- 1171 blockstates examined.
- 304 blocks reached an average colour; the rest were rejected by the table
  above.
- 136 distinct colours survive the default thresholds (noisiness ≤ 24, dedupe at
  ΔE 4). For comparison, the map colour source offers 60.
- Extraction takes **about 360 ms** on a 38 MB jar, and runs once per jar;
  everything after it reads the cache. (`tool/texture_palette_probe.dart` is the
  harness that measured it, and also writes the palette JSON.)

Noisiness percentiles over the survivors: 10% at 1.5, 25% at 7.4, median 14.3,
75% at 24.6, 90% at 38.6, 99% at 63.2. Concrete sits near 1, cobblestone near
29, glowstone near 63 — so a threshold around 20-25 is where the speckled
textures start falling out, which is why 24 is the default.

## Not verified

- **Whether a build made from this palette looks like the preview in game.**
  Lighting, shadows and resource packs all affect it, and the face brightness
  factors above may need tuning against a real build.
- **Whether the near-view speckle is acceptable.** The noisiness threshold is a
  guess about taste; it has not been judged on a real wall.
- The palette JSON has not been round-tripped through anything that reads it.
