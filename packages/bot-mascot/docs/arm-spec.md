# Bot mascot arm spec (Dylan's rules, consolidated 2026-10-28)

One source of truth for how the bot mascot's arms are drawn. Every rule here came from Dylan.
If a change breaks any rule, it's wrong, even if it fixes something else.

## Shape

- The arm is the locked flipper (A3 S-curve top, gentle underside, soft round tip, +10% length).
- No elbow, no kink. Bends are smooth. It may stretch to reach a target, keeping width and tip.
- Short reaches curl up more; long reaches straighten.
- Tiny arms (growing/shrinking, or very short reach in or out) are a crescent tip peeking out
  of his side, with both edges meeting his outline.

## Where it comes from

- Two fixed shoulder points, one per side. They never move.
- The arm always visibly comes OUT OF HIS SIDE. Both arm edges always connect to his side.

## Outline (the part we keep breaking)

- The bot mascot + his arms read as ONE character with ONE continuous outline.
- Where the arm leaves his body, his side outline between the arm's two edges is HIDDEN
  (the arm root covers it), and the arm's two edges flow out of his outline. No line across
  the arm's root, no gap, no separate side line, in EVERY pose: hanging, raised, out,
  across his front, across and out the far side, low, crescent.
- Where the arm lies in front of his body, it is a normal object in front: full fill and
  both edges outlined. Where it exits through his far side, his outline is hidden under the
  arm and the arm's outline continues.
- All lines smooth: no steps, notches, wedges, arrowheads, ticks, hooks, slivers or floating
  fragments.

## Colour

- The arm is his body colour with the same gradient in the same coordinate space, so it
  matches seamlessly inside and outside his silhouette.
- The arm is drawn in front of his body, so his shading never shows through it.
- Shading follows shading.md (one light, upper right).

## Layering

- Body → surface clothes (scarf band, tie knot, outfit fronts) → arm → drapes at the root.
- Arm in front of his body draws over surface clothes.
- Scarf tails: at rest/holding, the arm comes out from UNDER the tails. When the arm rises or
  moves out, it stays OUTSIDE the tails and over them, pushing them inward. The tails are never
  drawn over the arm, never split, and never go between the arm and his side.
- The arm draws over the eye.
- Props: body → arm → prop → hand tip. The prop is pinned to the tip, and the hand wraps from that
  arm's own side.

## Reach

- No gates: the tip goes where it's dragged.
- But never loop under his body like a trunk: low across targets lie across his lower belly.

## Process

- The arm is one drawing path used by Idle/Working/Calling/playground.
- Before every change: render root close-ups (3×) of the poses above and check them by eye at full
  size. Any stray black shape that isn't a smooth line = not done.
