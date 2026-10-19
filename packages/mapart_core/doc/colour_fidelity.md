# Colour fidelity notes

What was measured, what was changed, and what is still not possible.

Everything here comes from running the real pipeline on a real picture
(`B077CD3898AD5AA5511D581BD5CDFD0C.jpg`, a flat-shaded illustration) through
`tool/palette_lab.dart`, `tool/colour_probe.dart` and `tool/metric_probe.dart`.
Numbers are CIE76 unless stated. "blur" is the mean error after a 5x5 box blur
of both images, which is the fair way to judge dithering: error diffusion
deliberately raises per-pixel error to lower the error the eye actually sees.

## The palette is 180 colours, and that is fixed

The vendored table has 61 base colours. Staircase mapart can reach three shades
of each (255/255, 220/255, 180/255); the 135/255 shade needs water. Colour 10
(`Water`) has no full-solid-cube block at all, so its three shades are
unreachable too. That leaves **60 x 3 = 180** colours, and no choice of
representative block changes them — every block of a given base colour renders
identically on a map.

So "improving the palette" can only mean choosing better among those 180, not
adding to them. That claim is about *colours*. It is not about blocks, and the
two were conflated for a while — see the next section.

## Blocks: the palette was offering 60 of 209

Colours are capped, blocks are not. The vendored table carries **324** block
candidates across the 61 colours, of which **209** are full solid cubes defined
for the 1.20 block set. Every block of a base colour renders *identically* on a
map, so the block count changes nothing about the picture — but it is the whole
of the shopping list. White wool, white concrete, quartz and iron blocks all
show as `White Wool` bright, and which one you build with is a real choice: cost,
whether you have the material, and whether the build burns.

`Palette.select` picked exactly one block per colour and the app exposed those 60
and no others, which threw away 149 legitimate choices. `Palette.blocks` now
lists every candidate, and the app shows them grouped under their colour with
per-block toggles. Turning one block off hands the colour to the next one still
on; a colour only disappears once all of its blocks are off.

The groups are listed collapsed, each showing one shade strip for the colour and
how many of its blocks are on, and open to a row of **named** chips. Both halves
of that are deliberate. Collapsed, because sixty colours each showing their
blocks is a page and a half of scrolling before you reach anything else. Named,
because a bare row of swatches is unreadable: every block of a colour renders
identically on a map, so a correct palette *is* a row of identical squares, and
a row of identical squares tells you nothing about which one you are switching
off. That is what "why are there mysterious colour patches in the palette" is —
the swatches were not wrong, they were just anonymous. A row of 209 bare
swatches across 60 colours is also the single most confusing thing the app
showed.

The expanded palette is **pixel-identical** to the one-block-per-colour palette
until you touch it. That is not luck: within each colour the entry `select` would
have chosen is listed first, and `quantize` breaks an exact tie on the lowest
entry index, so the extra entries are only reached once the earlier ones are
switched off. `pipeline_test.dart` asserts the rendered bytes match.

A separate switch admits the blocks upstream flags as needing something
underneath them — slabs, carpets, sand, and `Water` itself. They are off by
default because a staircase is built from full solid cubes, but turning the
switch on takes the palette from 209 blocks to 323 and brings colour 10 (`Water`)
into reach, which is 3 more map colours. The flag is upstream's and is not
consistent (it is set on `slime_block` and `gravel`, both full cubes, and clear
on `mud_brick_slab`), so it is offered as a filter rather than trusted as a shape
test.

### What more colours would take

There is no room left. The base colour set is the game's, not the table's:
`MapColor` has had exactly 62 ids — 0 for transparent plus 1..61 for the colours
— since 1.17, and the per-version dump at `cerus/minecraft-map-colors` shows no
addition in any 1.21.x release. The 135/255 shade needs water over the block, so
a land staircase cannot reach it. 180 is the ceiling, and only the 135/255 switch
above can add to it, by 3.

## Where the palette falls short

`tool/colour_probe.dart` reports the closest distinct pairs and the most
isolated colours. Two things stood out:

- The palette is **not short of colours overall** — a dozen pairs sit within
  ΔE 2 of each other, so there are near-duplicates.
- It is short in one specific place. Scanning hue at L*65 with chroma 20/40/60,
  blue-cyan at 215-245 degrees is 14 ΔE from anything available.

That matters because the test picture is about 25% pale cyan. Its dominant
tones are `#c8e8f8`, `#b8e8f8`, `#b8d8f8`, `#c8d8f8`, and the best match for
all of them is `#dcdcdc` — neutral grey, at ΔE 13-20. Above L*80 the only
blue-ish colour in the whole palette is `#5cdbd5`, a saturated turquoise.

This is a property of Minecraft, not of the data: the map colour set is built
from the 16 dye colours and a few blocks, and there is no pastel cyan in it.

## What was tried

### CIEDE2000 instead of CIE76 — rejected as the default

CIEDE2000 does pick visibly more appropriate hues for some mid-tone targets:

| target | CIE76 picks | CIEDE2000 picks |
| --- | --- | --- |
| `#88a8c8` | `#a4a8b8` Clay (ΔE 12.4) | `#6699d8` Light Blue Wool (ΔE 7.2) |
| `#a8c8e8` | `#a4a8b8` Clay | `#a0a0ff` Ice |
| `#98c8d8` | `#a4a8b8` Clay | `#4fbcb7` Diamond |

But on the picture as a whole it did not help: mean error went from 10.31 to
11.04, blurred error stayed at 8.06, and the blue hair came out *whiter* than
with CIE76. It also cost roughly forty times as much (828 ms against 20 ms for
one map, before optimising the implementation). It is kept as
`ColorMetric.ciede2000` for anyone who wants it, but `cie76` is the default.

### Dithering — this is what fixes the pale colours

No single map colour is pale cyan, but a *mix* is. Roughly 75% `#ffffff` White
Wool bright and 25% `#6699d8` Light Blue Wool bright averages to about
`#cfd9f7`, which is close to the target. That is exactly what error diffusion
does.

Results on the test picture, all with the default drift budget:

| variant | per-pixel mean | blurred mean | exact % |
| --- | --- | --- | --- |
| no dither | 9.32 | 5.91 | 26.4 |
| dither, CIE76 | 12.73 | **3.06** | 26.4 |
| dither, CIEDE2000 | 11.35 | 4.51 | 26.4 |
| dither, threshold 0 | 15.63 | 1.99 | 26.3 |
| dither, threshold 20 | 9.32 | 5.91 | 26.4 |

Blurred error drops from 5.91 to 3.06 — from "clearly visible" to "hard to
notice". The per-pixel figure rising is expected and is the whole point of
dithering.

Re-measured after the ramp fix described under "The threshold was measured on
the wrong colour". Threshold 0 is unchanged by that fix, as it must be: with
the threshold off the ramp is always 1 and the pixel never takes its own
colour, so the two code paths agree by construction.

### A dither threshold, so flat regions stay flat

Dithering every pixel speckles the entire picture, including regions the
palette already reproduces exactly. `ditherThreshold` is the colour error below
which a pixel is left alone, so a region that is already right stays flat.
Beyond it the dither fades in by density — see "The ramp was throttling the
diffusion" below, which is the fix for what happened when it faded in by
strength instead.

Threshold 8 was chosen by eye. Threshold 0 scores better on the blurred figure
(1.99 against 3.06) but textures the flat greys; threshold 20 is too high and
turns dithering off in practice (it degenerates to the no-dither numbers).
Visually 8 is where the greys and the dark outlines stay clean while the hair
still reads blue.

### The threshold was measured on the wrong colour — fixed

A real illustration exposed a bug in this ramp, and the fix is the difference
between a usable preview and a speckled mess.

The ramp is supposed to ask "is this pixel already close enough to the palette
that dithering it would buy nothing?". It was asking it of the *error-shifted*
target rather than of the source pixel. That matters because the answer is used
to decide whether to pass the carried error on: measuring the shifted target
means that once error arrives from a region the palette genuinely cannot reach,
every pixel it crosses sees a large miss, re-arms the diffusion, and adds its
own small miss on top. A flat white shirt next to an unreachable blue stipples
from edge to edge — with white, the brightest colour in the palette, as one of
the two colours in the stipple.

On the illustration that prompted this (a 2x2 map, `b_4f2f34…jpg`, threshold 8):

| | before | after |
| --- | --- | --- |
| per-pixel mean ΔE | 9.58 | 7.44 |
| per-pixel p95 ΔE | 32.9 | 23.6 |
| blurred mean ΔE | 3.23 | 4.59 |

Both per-pixel figures improve; the blurred figure gets worse. That is the
trade being made, and it is the right one here: the blurred number was being
bought by texturing regions that were already correct, and a region that is
uniformly 3 ΔE off reads far better than one that is correct on average and
speckled. A pixel inside the threshold now takes its own best colour and the
error it was carrying is dropped rather than passed on.

Two counts make the mechanism plain. Of the source pixels, 62% are within ΔE 8
of one of the 180 colours — those are the ones that should never have been
textured — and 38% are further away, concentrated at ΔE 9-11 and 18-19. The
18-19 cluster is the documented pastel-cyan gap, which still has to dither.

`quantize_test.dart` pins the behaviour: a near-white region downstream of an
unreachable cyan one must come out as a single colour. Against the old code that
test fails with `{Rgb(255,255,255), Rgb(220,220,220), Rgb(160,160,255)}` in the
region that should be flat.

`tool/dither_probe.dart` is the harness that measured the histogram and the
region biases.

### The ramp was throttling the diffusion, not the dither — fixed

The ramp above decides *whether* a pixel dithers. It was also being used to
decide *how hard*, by scaling the error handed to the neighbours. That second
use is a bug, and it is the one a real illustration exposed as "why is there a
random colour patch".

Error diffusion corrects a region's average colour *because* the whole error is
carried: the residual accumulates until the choice flips to the next colour
along, and the run of flips is what averages out. Carrying a fraction of the
residual does not fade the dither in, it breaks the mechanism — the region ends
up both textured and the wrong colour, which is the worst of both.

Measured on the cheek of `1.png` (a pale, desaturated pink the palette has no
colour for; the nearest is `White Terracotta` bright, a beige, at ΔE 10.8):

| | mix of beige : pink | region mean ΔE |
| --- | --- | --- |
| ramp scaled the diffusion (before) | 9 : 1 | 6.83 |
| ramp scales the density (after) | 59 : 27 | 2.93 |

At 9:1 the region is a flat beige patch that is visibly the wrong colour, with
a hard edge where the ramp crosses zero — a region that is *not* corrected reads
as a patch of paint, and the eye picks out its boundary immediately. At 59:27
the average is right and the boundary is gone, because the dither's density
fades in rather than its strength.

The fade is now spatial: an 8x8 Bayer mask picks the share of pixels that take
part, so a pixel at 1.35x the threshold dithers at full strength and 35% of its
region joins in. Pixels beyond the threshold that the mask does not select still
*paint* their own best colour, but they pass the error on instead of dropping
it — otherwise 65% of the region's error is thrown away and the average cannot
be corrected at all, which is what a first attempt at this did (region mean ΔE
8.50, worse than the code it replaced). Only a pixel *inside* the threshold
drops the error, which is the containment described in the previous section and
is what keeps a flat white area next to an unreachable blue from stippling.

Whole-image effect, both figures being the mean CIE76 error before and after a
3x3 blur:

| | `1.png` 1x1 | | `b_4f2f34` 2x2 | |
| --- | --- | --- | --- | --- |
| | per-pixel | blurred | per-pixel | blurred |
| before | 5.96 | 4.28 | 7.41 | 4.83 |
| after | 6.70 | **3.92** | 8.43 | **4.53** |
| every pixel dithered at full strength | 7.35 | 3.31 | 9.12 | 3.93 |
| no dither, for reference | 9.32 | 5.91 | - | - |

The blurred figure improves on both pictures, which is the figure the eye
integrates. The per-pixel figure rises, as it must — that is what dithering is.
The third row is the version with the threshold switched off entirely: better
still on the blurred figure, and it textures regions the palette already
reproduces exactly, which is what the threshold exists to prevent.

One cost is real and worth stating: conserving the error means an individual
pixel can be pushed further from the source before the error is spent. Pixels
more than ΔE 40 from their source go from 24 to 1614 on the 2x2 picture, out of
65536. They are the dots that make the average come out right; suppressing them
is the same act as suppressing the mixing, and capping the carried error was
tried and measured to do exactly that (see the note in `quantize.dart`).

Three alternatives were measured and rejected before this one:

- **Scale the diffusion by the ramp** (the behaviour being replaced) — correct
  regions stay clean, but every region beyond the threshold is left wrong.
- **Dither every pixel beyond the threshold at full strength** — blurred error
  falls to 3.31 / 3.93, the best of any variant, and it turns a face into a
  field of dots. The threshold is supposed to keep *flat* regions flat, and a
  region at 1.35x the threshold is not flat.
- **Raise the threshold to 10, 12 or 16 on top of the density ramp** — blurred
  error degrades monotonically (4.38, 4.60, 4.77 on `1.png`; 5.16, 5.63, 5.96
  on the 2x2) as more of the picture stops being corrected at all. This is the
  control to reach for when a build wants to look flatter, not a new default.

`tool/render_png.dart` renders a picture and writes the target, the result and
the two side by side, so a change can be looked at rather than inferred from a
mean; `tool/region_probe.dart` answers "why does this rectangle look like that"
by listing the palette tones the render actually used there and how often. The
region figures above come from the second one.

### A drift budget, so the build fits in the world

Dithering pins every pixel's shade, and the shade decides whether the surface
steps up, stays level, or steps down. Left unbounded the walk is essentially
random and grows with the image: measured spans were 211 layers for one map and
**935 layers for 5x5**, which is more than twice the overworld.

`QuantizeOptions.driftBudget` caps the drift within a column. `suggestHeightPlan`
derives it from the target version's build limits and also returns a base height
that centres the result. The budget only binds when it has to:

| drift budget | span | blurred mean |
| --- | --- | --- |
| unbounded | 140 | 3.06 |
| 96 | 108 | 3.75 |
| 64 | 76 | 4.89 |
| 32 | 44 | 6.48 |
| no dither, for reference | 140 | 5.91 |

For a single map the suggested budget is 181 and does not bind at all. For 5x5
it does, and the build lands at 363 layers — inside the overworld with room to
spare, and still far more faithful than not dithering.

### Error diffusion strength — not worth changing

Backing the diffusion off to 50% gave a blurred error of 5.24 against 3.06 at
full strength, for a modest per-pixel improvement. Full strength is the default;
`ditherStrength` is exposed for anyone who wants a quieter texture.

### Chroma-weighted matching — pastel colours keep their hue

A chibi illustration (pastel cyan hair, pale pink skin, flat fills) exposed the
worst case of the CIE76 behaviour noted above: the hair, far from every map
colour, quantised to *grey* — `#dcdcdc` is closer in lightness than any cyan,
and the chroma difference is only one term of the distance. The picture read as
drab even though a same-hue colour (`#5cdbd5`, turquoise) was available, and
CIEDE2000 — the metric that fixes this on paper — costs forty times as much.

`ColorMetric.chromaWeighted` is CIE76 plus a penalty on candidates *less*
chromatic than the target: `(targetChroma - candidateChroma)^2` when positive,
zero otherwise. Two multiplies in the inner loop (both chromas are precomputed),
and it degenerates to plain CIE76 for achromatic targets, so photos and greys
are untouched.

Measured on a synthetic flat-fill image (`tool/make_synthetic.dart`,
`tool/color_lab.dart`), per-pixel / blurred CIE76:

| variant | mean | blurred | hair |
| --- | --- | --- | --- |
| flat, CIE76 | 6.47 | 6.16 | grey |
| flat, CIEDE2000 | 7.11 | 6.90 | turquoise |
| flat, chroma-weighted | 7.12 | 6.92 | turquoise |

The weighted metric matches CIEDE2000's pick at CIE76's price. It is the app's
default; `cie76` stays the core default so the numbers in this document remain
valid, and `quantize_test.dart` pins both the hue preservation and the
achromatic degeneracy.

Two things it does not do, on purpose:

- It does not make pale colours reachable — pastel cyan still has to dither,
  and with the weighted metric the dither mixes white with a *same-hue*
  saturated colour instead of drifting towards grey, which is the difference
  between "textured cyan" and "confetti".
- It slightly inflates the reported cost of chromatic targets, so the dither
  threshold bites a little earlier for them. That is the same trade the
  threshold always makes and is visible, not hidden.

### The density ramp mask is blue noise, not Bayer

The threshold ramp fades the dither in by *density*, picking pixels with a
fixed mask. The mask was an 8x8 Bayer matrix, and at mid-ramp a Bayer matrix
selects a perfect checkerboard — the single most visible binary pattern there
is. A pale region at ramp 0.5 became a regular grid of dots that read as a
printing defect.

The mask is now an 8x8 void-and-cluster (blue noise) matrix, generated
deterministically at startup (fixed seed, gaussian over wrap-around distances,
Ulichney's algorithm — 64 cells, so generating beats hard-coding a table
nobody can audit). The density semantics are unchanged: a region at ramp 0.5
still dithers half its pixels, but the dots sit as far apart as possible
instead of on a lattice, so the texture reads as grain rather than as a grid.

### Same-shade blue-noise halftone — rejected

The idea was to mix two colours at the *normal* shade only, placed by the
blue-noise mask, so a pastel would read as the mix without the staircase
Floyd-Steinberg builds. `DitherMode.halftone` does that.
`tool/halftone_probe.dart` re-runs the comparison.

It cannot work, for a reason that is the shade rule rather than the mask. A
column that stays flat shows the normal shade on every pixel. Bright and dark
only exist where the surface steps. White at the normal shade is `#dcdcdc`,
and that is the lightest paper a flat mix can use. Pale cyan wants real
white, which is the bright shade, and a column of bright shades is a
staircase one block taller per row.

On a flat `#b2ebf0` fill, chroma-weighted, threshold 8:

| variant | blurred, 5×5 | span |
| --- | --- | --- |
| no dither | 22.95 | 33 |
| Floyd-Steinberg | 5.30 | 65 |
| halftone | 16.99 | 1 |

The height claim holds and the colour claim does not. On the illustration,
threshold 0 so every pixel may mix, the halftone's blurred error is 8.26
against 7.96 for no dither and 2.08 for Floyd-Steinberg, and the span only
moves from 50 to 46. The app does not offer the mode.

### OkLab instead of the chroma-weighted metric — rejected

The app matches with `ColorMetric.chromaWeighted` (CIE76 plus a penalty when
the candidate is less colourful than the target) and spreads the error with
Floyd-Steinberg. CIEDE2000 was already rejected as the default. OkLab is the
other cheap Euclidean space people reach for when CIE76 sends pale hues to
grey, so it was measured the same way. `tool/metric_probe.dart` re-runs it.
Blur is 5×5, in CIE76, whatever metric did the matching.

OkLab agrees with CIE76 about the problem case. `#b2ebf0` is nearer to
`#dcdcdc` (distance 0.059) than to `#5cdbd5` (0.101), so the undithered pick
is grey.

Floyd-Steinberg, threshold 8, on the illustration at one map:

| metric | blurred | quantize | sample pixel |
| --- | --- | --- | --- |
| chroma-weighted (current) | 2.70 | 94 ms | `#6699d8` |
| CIE76 | 2.87 | 100 ms | `#dcdcdc` |
| CIEDE2000 | 3.53 | 1021 ms | `#dcdcdc` |
| OkLab | 4.78 | 67 ms | `#dcdcdc` |

Nothing here beats the current metric. CIEDE2000 is an order of magnitude
slower and the sample stays grey. OkLab is the worst of the four on this
picture. The app still defaults to chroma-weighted.

## Bugs this work uncovered

- **The solver's search window was clamping dithered images.** With dithering
  the shade of every pixel is pinned, but the flatness dynamic program still ran
  and its window forced pixels onto shades the dither had forbidden. A one-map
  build came out at 96 layers instead of 140 and the dither's average colour was
  destroyed (blurred error 4.85 instead of 2.04). The solver now solves greedily
  whenever the image is dithered, and says so in `warnings`.
- **The dynamic program was far slower than it needed to be.** It explored
  states that provably cannot be on an optimal path. Bounding the window by
  where the drift penalty must outweigh any colour saving, and skipping offsets
  that are unreachable at a given row, took a 5x5 solve from 6624 ms to 3107 ms.
- **The last-row search range was off by one**, which silently returned a
  suboptimal walk instead of the optimum.
- **`fitsWorld` was derived from "no warnings at all"**, so an informational
  note about dithering would have been reported as a height problem. It now
  reflects the actual height against the version's limits.

## Still not possible

- A pale, desaturated cyan as a *single* block. Only a dither can approximate
  it, which costs build effort and looks textured close up.
- Anything above `#ffffff` (White Wool bright) or below the darkest available
  colour. The gamut clamp in the dither stops those regions from speckling
  against a wall, but they stay at the nearest reachable colour.
