# The bot mascot's shading: one light

**The light comes from the upper right, everywhere.** Every part of the bot mascot, his arms, his props and what he wears
is lit from up and to the right. Its shade falls on the side away from the light, the lower left.

There's one constant for it: `LIGHT = [6, -10]` (`src/render/frame.ts`), the nudge toward the light, 6 right and
10 up, in the bot mascot's own space. The original intro videos used the same values.

## The method

A shape's shade is the shape less a copy of itself nudged toward the light. What's left is a band along the
lower-left of the form, and it's drawn in the palette's `shade` colour. It's the same method as before, only
nudged the other way.

## How each kind of part is shaded

- **His body.** Live, every frame, from his live outline: his silhouette less itself nudged. That gives a band
  down his left side and along the bottom of his body and legs; the upper right is lit. The intro draws the same
  band, softened, through its morph.
- **Layers.** Each part's shading belongs to its own layer. His body's shade is in his body layer, under any
  arm: arms are drawn on top of his body and its shade pass. Nothing of his shade is ever drawn on an arm, and
  his shade pass is his body's alone. An arm never cuts into it, and never carries it.
- **Arms** (the rig, the playground and Working; `arm-rig.md`): an arm is drawn in front of his body and his
  shade pass, so his shading never shows through it. It has only its own shading, from its own form and the one
  light, crisp as his.
  - **The screen-left arm**, on the shaded side, gets its own band: the arm less itself nudged. Its root (carried
    back past where it comes out of his side, and its mouth over his outline) counts as its form, so the root has no
    band of its own.
  - **The screen-right arm**, on the lit side, has no band of its own.
  - **A crescent** (a small arm at his side) is part of his side: shaded with him as one form, easing into its own
    form as it grows.
  - **Heading out of his side**, the arm's root carried back into him is drawn in his body layer with him and the
    arm as one form, so his side band ends where the arm, nudged toward the light, lies over it, instead of running
    on across the root.
- **Hands** (`src/effects/hands.ts`): the hand less itself nudged toward the upper right, so the shade sits on its lower
  left.
- **Props:**
  - **The clipboard:** a soft wash darkening from the lit upper right to the lower left, on the board and on the
    page.
  - **The phone:** the handset's depth side darkens, and its face is lighter toward the upper right. The handset
    keeps its own drawn shading as the rig turns it.
- **Hats, eyewear and outfits:** lighter toward the upper right, darker toward the lower left (and underneath).
  The `litGradient` helper (`src/color/colors.ts`) runs from the upper right to the lower left; the lens tint
  does too, and the tie's and the suit's sheens are lit from the upper right.
- **Glare:** shiny things (lenses, the crown, the duck, the antenna ball, the propeller cap, the top hat's band,
  the jack-o'-lantern) get one crisp white curved streak on their upper-right edge, and at most one tiny dot.
  Fabric gets no white at all.
- **The eye glint:** up and to the right (`glint.light`, −45° in screen space), the same light.
