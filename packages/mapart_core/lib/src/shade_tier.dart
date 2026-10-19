/// Which shade of a base map colour a block shows.
///
/// Minecraft picks the shade by comparing a block's height against the block
/// immediately to its **north**:
///
/// * higher than the northern neighbour -> [bright] (255/255 of the base colour)
/// * same height                        -> [normal] (220/255)
/// * lower than the northern neighbour  -> [dark]   (180/255)
///
/// The 135/255 tier, [water], is only reachable when the block sits under
/// water, so staircase mapart never produces it. It is modelled anyway because
/// the vendored colour table carries a value for it and the arithmetic test
/// covers it.
///
/// Staircase mapart inverts this: rather than deriving the shade from a height
/// that already exists, it chooses the shade it wants per pixel and then makes
/// the heights produce it.
enum ShadeTier {
  /// 255/255 of the base colour. Block is *higher* than its northern neighbour.
  bright(255, 'light'),

  /// 220/255 of the base colour. Block is the *same* height as its northern
  /// neighbour.
  normal(220, 'normal'),

  /// 180/255 of the base colour. Block is *lower* than its northern neighbour.
  dark(180, 'dark'),

  /// 135/255 of the base colour. Underwater only; unused by staircase mapart.
  water(135, 'unobtainable');

  const ShadeTier(this.numerator, this.upstreamKey);

  /// Numerator of the shade fraction; the denominator is always 255.
  final int numerator;

  /// Key used by the vendored MapartCraft table's `tonesRGB` object.
  ///
  /// Note that upstream's `light` is the *base* colour, i.e. the 255/255 tone.
  final String upstreamKey;

  static const int denominator = 255;

  /// The shade as a fraction of the base colour, in `(0, 1]`.
  double get multiplier => numerator / denominator;

  /// The three tiers staircase mapart can actually produce, brightest first.
  static const List<ShadeTier> staircase = <ShadeTier>[bright, normal, dark];

  /// The height delta, relative to the block to the north, that produces this
  /// tier. `+1` means "one block higher".
  ///
  /// The magnitude is fixed at one on purpose: for a run of `n` pixels needing
  /// the same tier, a step of exactly one is the *smallest* total drop, so it
  /// keeps the build as flat as possible. Larger steps would only make the
  /// staircase taller without enabling any shade that one step cannot.
  int get heightDelta => switch (this) {
    ShadeTier.bright => 1,
    ShadeTier.normal => 0,
    ShadeTier.dark => -1,
    ShadeTier.water => throw StateError(
      'ShadeTier.water is not reachable by staircase mapart',
    ),
  };

  /// The tier a block at height [height] shows when the block to its north sits
  /// at [northHeight]. Inverse of [heightDelta].
  static ShadeTier fromHeightDelta(int delta) {
    if (delta > 0) return ShadeTier.bright;
    if (delta < 0) return ShadeTier.dark;
    return ShadeTier.normal;
  }
}
