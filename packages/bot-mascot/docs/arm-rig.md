# The bot mascot's arm rig

One set of arm mechanics, the same for every animation and prop: the arm rig in `src/arms/`. Animations don't hand-tune arms. They choose a **target** for the tip and how far the arm
is **grown**, and the rig does everything else.

```ts
const ctx = renderContext()
const pose = idleAt(t)
const svg = renderBotMascotFrame(ctx, "sunny", pose, { uid: "u" })
const torso = { d: bodyPathOf(svg), shoulderY: ctx.body.shoulderY }
const p = poseArm(torso, { side: 1, grow: 0.8, target: [440, 300], grip: phoneProp("sunny") })
const drawn = drawRig(ctx, svg, p ? [p] : [], { uid: "pg", pal: "sunny", pose })
```

`torso.d` is his body path (`data-r="body"` in a frame from `renderBotMascotFrame`). Targets are in his body space (0–500, feet at y 412).
`side` is +1 for the screen-right arm and −1 for the screen-left arm.

## The rules

- **One pivot.** There is exactly one pivot per side (`armOrigin`), and it never changes. Every arm shares it
  (Working, Calling, the playground): the spine's root of an arm lying along his outline from the shoulder, whose outer edge starts on his outline at the shoulders'
  height (`body.shoulderY`: 322.1 on his official body, 292 on the original; see Body zones). Every
  arm grows, raises and reaches from that point, and no rule moves it: not the angle, not the grow amount, not
  raising the arm.
- **Grow.** `grow` runs from 0 to 1. The arm grows out of the pivot, scaled up in length and width, while it
  swings from the bud's angle into its pose. A bud starts inside him and comes out of his side; nothing of it
  shows until it's out, and under 2% grown there's no arm. Shrinking back is the same thing run backward.
- **Reach.** The spine ends exactly on the target. The arm stretches as long as it needs to (no cap) and bends
  smoothly with the rig's one curve (`CURVE`: almost straight at the shoulder, bending more toward the tip), no elbow.
  - **A shorter reach is the same arm, shorter** (Dylan: "we just need to make the arm shorter, we don't need to
    redraw the entire arm"). A target nearer than the medium reach (`MED`, 2.7
    flipper lengths from the pivot) gets the medium arm toward it, its tip slid back along that same arm to the point
    nearest the target and the shortened arm, unchanged, turned about its root to point at the target. It's never
    solved again into another shape, so never a loop, bean, hook or blob; very short, it's a small flap out of his
    side. The tip goes near the target, not contorted to touch it exactly. Every curl and arc below is one fixed
    amount, the same at any length.
  - **Every target gets the normal arm** (Dylan):
    aimed at the target from the opening, its two edges running all the way from the opening to the tip, as an
    across reach's do. There's no low-target hold curl (setting off down along his side and curling round, which
    left only a closed round blob of a hand showing); only the grow and shrink-back show a crescent.

  - **The bend, by the hand's quadrant** (Dylan; `poseArm`'s `bendOf`). Which
    way the arm bends is decided by where the hand is from the shoulder (above/below × out past him/across him).
    "Up" always means the hand end turns up, whichever way the arm points.
    - **Out (and straight up or down from the shoulder):** the flipper's own **upward curl** (`upCurl`), only
      out past his outline (eased in over 20 round it): `UPCURL`, 15°. Over him there's none.
    - **Below the shoulder and across him:** a **scoop**, the arm dipping from the shoulder and the hand turning up
      toward the target, like a cupped hand (`SCOOP`, 40°), never a sag with the hand drooping.
    - **Above the shoulder, on him (his head, the top of it, his forehead):** **across his front** (Dylan): the arm leaves the opening heading in and up over his front and
      curves up to the hand in one even arc, like an arm reaching up across the chest to touch the top of the head,
      never arching round the outside of him (`ACROSS`, 70°). It comes in with how steeply up the hand is (from
      25° to 55° above level: a reach across him at about his shoulder's height is the straight reach across). Leaving up and into him, the inner edge sets out from the opening's lower end and the outer edge on
      up his side from the upper.
    - **Above the shoulder, out past him:** the upward curl, and reaching up steeply, the arc up and over (below);
      only once the hand is clearly out past his outline (from 15 to 40 out).
    - **Blending, no pops:** outward eases into across from 20 to 60 across him from the shoulder (so a hand
      straight below keeps the flipper's curl), and above into below over 16 either side of the shoulder's height,
      so dragging the hand round never flips the bend.

  - **Reaching up** (the rig's arms, `poseArm`): an arm that would leave steeper than 45° above level (up his own
    side) leaves at 45° instead, out from his side, and curls up and over to the target in one even arc, so it
    never runs up beside his outline: one arc of `CMAX` (90°), leaving up to 55°. A target on him or just past his
    outline is reached across his front instead (above). Either way the arm comes out of its opening, his outline hidden between its edges,
    never running straight up along his side over his face.
    Round toward his middle, from 120° round from straight out, it eases into the straight reach across him, so
    dragging round from over his head to across his body is smooth.

  - **Reaching down, never along his side** (Dylan).
    An arm leaving the opening nearly parallel to his side has its outer edge lying on his outline, so there's no
    join and the arm reads as a shape stuck on his side. So a downward reach leaves at least `DOWN_OUT` (30°) out
    from straight down, bowing out of his side and curving down to the hand, when the hand is out past straight
    below the pivot; or at least `DOWN_IN` (50°) in from it, in over his front, when the hand is down across him.
    The switch is eased over 4° of the hand's angle from the pivot (94° to 98° round from straight out). An edge that sets off from its end steeply
    into him (over 25° off his outline) is never laid on his outline. Both edges peel off his side at the opening
    in every hanging pose.
- **Reach anywhere** (`poseArm`). There are no gates: the tip goes on the target (near it, for a short reach), anywhere on the canvas,
  for either arm. That includes up his own side, over his head, behind the pivot, right at it, and across to his
  far side and out past it. The arm bends to get there, with no elbow, the locked width and tip, and a seamless
  root. A target inside him near the pivot gives a short arm lying in him, mostly hidden there (its tip is still
  on the target). The arm is picked at the press, as before.
  - An arm curled back over him (up and over toward his middle) can have its top edge, inside the curl, lying
    all over him while its underside comes out of his side. The drawing then treats the underside as the edge
    that leaves him, joined flush, and the top edge as the line lying over him.
  - An arm lying over him from the root is kept inside his outline near the pivot, so its root's corner never
    sticks out past his side as a bump, and its fill never covers his outline in a notch.
- **Drawing** (`drawArm`; the rules are `arm-spec.md`). One model for every pose, with no per-case
  pieces: the bot mascot and his arms are **one silhouette**, and an arm in front of him is a **normal object in front**.
  - The locked flipper (A3 at +10%), stretched evenly, with its tip cap, from its root by the pivot (in him).
  - **One shape at the shoulder, the arm in front** (Dylan: "one big shape where all lines
    properly connect"; the arm is a separate layer in front of him, only its root is
    one with him). `compose` unions his body with each arm's ROOT only (Clipper, the `clipper-lib` package, Boost licence):
    the arm within `ROOT` (34) of its opening, plus, within `NEAR` (70) of it, any of the arm lying within a line's
    width outside his outline (an edge running alongside his side is then the one line with it, never two). The union
    is closed (out by `CLOSE`, 10, and back in), which rounds the armpits, filled once and its boundary stroked once,
    as his own outline is (16 under the fill, 8 showing), so at the shoulder his outline and the arm's run into each
    other and can't come apart. His outline is sampled finely (every cubic at 24 points, `densePoly`), so the boundary
    is a smooth curve, never steps.
    - **The rest of the arm is its own object in front of him:** its fill (its outline made a simple polygon, so an arm
      curled over itself never has a hole) and its own outline, one stroke along both its edges and round its tip, 16
      under its fill, so 8 of it shows round the arm everywhere, over him too. It starts on the shape's boundary at the
      shoulder (it leaves out only what the boundary already draws: the root's edges and the armpit rounds), and it
      covers his outline wherever it passes over him: his legs and feet, his crotch, his other side, his head.

    - **No crack, no sliver at the root** (Dylan): the shape never has a
      hole (a hair-thin crack between an arm's root and his side is filled), and an arm edge running alongside his
      outline just inside it near the shoulder (3 to 7 in, within about 20 degrees of parallel, eased along the edge)
      is laid on his outline, so its line and his are one line, never a notch with a sliver of his fill between them.

    - **Never a free end:** a line that ends inside the shape runs on along the arm's own outline to where that is the
      boundary; reaching the opening's end that way (an arm up or down his side, its other edge covering him past
      that end), it runs on along his outline across the opening, the way that runs least under the arm, to where his
      outline is the boundary again and isn't under an arm, and joins it there.
    - **In front of something** (his eye, clothes, a board): the arm, as above, drawn again at that layer.
    - Then the clothes, eye, prop and hand, and drapes layers as before. The bot mascot's own body stroke is replaced by the
      shape's whenever an arm is out.
    - **Fast enough for every frame** (Dylan: "runs very slow"): the costly geometry (the roots, the band, the close
      that rounds the armpits, the shape's inside) is worked out only in a box round each opening (`BOX`, 100 either
      way); what the close adds there (the armpits' rounds) is unioned with his whole body and the roots, so no box edge
      is ever in the shape. His curves are sampled at 24 points only near an opening, 6 elsewhere; each arm's polygon is
      simplified once a frame; offsets thin near-collinear points first (by at most 0.03: any more cascades along a gentle
      curve into a chord, and the armpits' rounding then leaves a sliver past his side, stroked as a thick blob) and use mitred joins for the
      small insets. In
      the original builder, in headless Chrome, a frame of Working took about 11 ms, Calling and the playground about 7 (they took 219, 226 and
      145 ms with the whole-body union), and the builder held 60 fps in Idle, Working, Calling and a playground drag.
  - **Where it comes out of his side is fixed** (Dylan): the mouth, the stretch of
    his outline at the shoulder centred on the point of it by the pivot, as wide as the flipper there. Every arm, in
    every pose, leaves his side there: each edge sets out from its end of the mouth, its corner with his outline
    rounded (radius about 7) so the lines meet in soft corners, never square steps; (the edge on the flipper's top
    side from the end on that side) and curves into the flipper's own edge over a flipper length and a third
    (setting out a little squarer to his outline when it heads into him). Nothing about the target slides the root
    along his side or widens it; only the arm's way and bend change. His outline between the mouth's two ends is
    always covered by the arm (out to his outline's edge), in every pose (hanging, along his side, raised, out,
    across, crescents, Working, Calling), with no angle threshold, so nothing crosses the root, and no more of his
    outline than that is ever hidden. Which edge sets out from which end is one smooth score (the cross-section's
    lie along his outline, plus, for an arm leaving downward, the outer edge trailing the way the arm goes along his
    side), never letting the two edges cross (of two ways round that don't, the score's; no other tiebreak). Hanging
    down his side, the outer edge runs on from his outline across the opening and the inner edge leaves from the far
    end. An arm leaving upward is decided by the cross-section alone, so the choice changes over only where the arm
    leaves straight up, where the two ways round coincide: a short reach up and across toward his eye stays one smooth
    flipper as the hand moves, never flipping into a hook (Dylan). An edge lying along his side, just inside or out, is laid
    on his outline (one line). Every line either joins the outline or isn't drawn: an inner edge setting out along his
    side ends in a round end lying in his outline's line, never a separate piece.
  - **The crescent:** a small arm is just a small bump of the one shape out of his side. (The mirrored
    crescent reaching in is gone with the old drawing.)
  - **Fill:** his body gradient (the same gradient, the same space), over his body, his shading, his outline and
    his clothes. An outfit's sleeve covers the arm and its mouth.
  - Blush stays on his face only.
- **Shading** (`shading.md`): one light, from the upper right. A shape's shade is the shape less a copy of itself
  nudged toward the light, a crisp band along its lower left, as his own.
  - His body's shade belongs to his body layer, under the arm: nothing of his shade shows through an arm.
  - The screen-left arm has its own band: the arm less itself nudged, its root (carried back past it, and the
    mouth) counting as its form, so its root has no band of its own. The screen-right arm, on the lit side, has none.
  - A crescent is part of his side, shaded with him as one form (it eases into its own form as it grows).
  - Heading out of him, the root carried back into him is drawn in his body layer (under his clothes) with him and
    the arm as one form, so his side band ends where the arm, nudged, lies over it instead of running across the root.
- **Draw order** (`compose`). The arm is a layer **on top of his eye**; it isn't masked off it any more. This
  replaces the old "eye never covered" rule. Every arm goes in his body layer, and where it's in front of
  something it's drawn again as an exact copy at that layer. `poseArm` arms are in front, so an arm reaching over his
  face covers his eye.
  - `front`: over everything.
  - `between`: over a board but under its page.
  - `frontClip`: only over a prop's silhouette.
- **Props** (Dylan's rules). Holding something, the arm wraps it like a hand, by layering: his body, then the arm,
  then the prop, then the hand.
  - **The arm under the prop.** The whole arm (from his side up to the hand, root lines and all) is under the
    prop's layer. A very short arm, right against his side, is hidden by the prop wherever it lies under it.
  - **The hand over it** (Dylan: one clean grip, the same for any held prop). The arm runs under the prop, and over
    it there's one clean closed hand: the arm's round tip folded back over the grip, a smooth rounded mitten of a
    fixed size (`HAND`: 29 along the arm, 22 across, a superellipse; about the flipper's width), scaled with the
    arm, in his colour with his outline (a 16 line under its fill, as his own). It's centred on the grip at the
    arm's end and lies along the arm's way there, so it wraps from that arm's own side. Its fill hides whatever is
    under it, so the arm's edges go under the hand, never through it, with no second loop. It looks the same at
    every pose (at his ear, yelling, the wind-up, held out, held across, at the
    tip).
  - **Drawn the same.** Without a prop, the arm is unchanged. With one, the arm's pose and drawing are the
    same; only the prop and the hand (its tip again) are added.
  - **Per prop:**
    - `grip` is the local point the hand closes on.
    - `gripDir` is the local direction that turns to the way the prop lies across the hand.
    - `past` is how far the grip point is from the hand's fold.
    - `over: "hand"` draws the hand over it.
  - **Clear of his side:** near his outline (a short reach by his side, the hand within about 45 of it), a pinned
    prop turns, over the top, so its bulk hangs out from his side rather than over it.
  - **Pinned to the tip** (no pose given): the prop's grip goes under the hand, at the arm's end, its `gripDir` turned
    to the way the hand lies across it, in from that arm's side, all but level, so the prop stands upright (at his
    ear, upright beside his head).
  - **A given prop pose** (`propM`, body space, e.g. an animation's): the prop is drawn as given and the arm reaches
    its end to the grip, the hand over it as above. `src/animations/calling-swap.ts` uses it.

## Who uses it

- **Working** (`src/animations/idle-working.ts`). It drives the rig exactly as the playground and
  Calling do, with targets only (Dylan): each arm is
  `poseArm(body, { side, grow, target })`, so it comes out of its fixed opening with the rig's connection and the
  one-path outline. It has no arm code of its own (the old hold, `WorkingHold` / `HoldSilhouette2` /
  `WorkingArms`, its own reach and the carry's taper are gone). Its choreography is its own:
  - **Targets:** each tip just in over the board's side edge at its middle height (the hold); the right arm's
    page-carry path round the board (out round its side, behind it, the page's edge up, over and down our side,
    and back); `grow` the Idle ↔ Working swing (the arms grow out of their openings and shrink back in).
  - **Layers:** the hold arms in front of everything (the hand over the board); the carrying arm behind the board
    while it reaches round behind it and carries the page up, over the board but under the page once the page
    hangs on our side (`compose`'s `between`).
  - The board, its pop, the page flip's timing and the reading are Working's own, unchanged.
- **The builder's Arm playground.** Press on the bot mascot and the arm whose shoulder is nearest the press grows out.
  Drag and its tip follows; it stays the same arm for the whole drag. Let go and it shrinks back in.
- **Calling** (`src/animations/calling-swap.ts`). It's the
  original Calling with the rig's arm and hand in place of the floating hand. The phone's pose is given
  (`propM`, held from its back), so the hand is locked to the grip.
  - **Start:** the phone springs in on its own, and the arm reaches for it and takes it.
  - **Throw:** the throw is Dylan's (facing the throw, high, spinning, a little lower off the left). The arm
    follows through, then shrinks back.
  - **In the builder:** it's a mood. Leaving it, the phone pops away and the arm shrinks in (`EXIT`) before
    the next mood's arms come in. Coming from Working, it waits for Working's arms to swing out.

## Body zones

`bodyOf({ dy, y0, neck })` (`src/body/zones.ts`) gives him a head, a neck and
a torso.

- **Taller:** the extra body `dy` goes in under his eye (his outline from 300 to 340 is stretched). His head
  rides up by `dy`: the eye, makeup, eyewear, hats and a phone at his ear. Clothes follow the stretched body,
  and his legs stay.
- **Neck:** the scarf and tie move up by `neck`, so the scarf's wrap sits just under the goggles' frame.
- **Shoulders:** the arms' shoulders (`body.shoulderY`) are `up` (3) above the zones' shoulders `y0`. It was 15
  (Dylan: "a bit higher on the character"); lowered 12 (Dylan) so an
  arm's fixed root sits wholly inside the overalls' arm hole, the straps passing above it: the straps meet his side
  `STRAP_CLEAR` (12) above the top of the arm's root and the bib's top is 4 higher. The tops (suit, dress, robe) are
  laid out from the root and clear it (`TOP_CLEAR`). The root is still one fixed point per side; only where it is
  moved.
- **Layering:** arms over clothes, and the goggles' strap and the scarf's tails behind the arms, as ever.
- **Official body (Dylan, locked):** B, 15% taller (`officialBodyZones`: `dy` 33.9, arms' shoulders 322.1, neck 40.9).
  It's the default everywhere: `renderBotMascotFrame`, the rig and the builder.
- **In the builder:** his body is always the official one; the Height control is gone (Dylan). Old share links
  with `ht=` ignore it. After the intro (pre-rendered on the original body), the official body eases in.

## Outfits and arms

- **Tie:** the neck zone, above the shoulders; layered by the depth model below. (The scarf is gone for now, Dylan:
  old share links with it fall back to no outfit.)
- **Tutu:** the waist zone (`waist: true`). Its waistline sits 11 under the shoulders and its hem at 376,
  below the arms.
- **Overalls:** on the zoned body the bib's top sits just under the clothes' shoulders. Each strap goes up over
  his shoulder from the bib's corner to his side just above the top of the arm, and the bib's side is below it, so
  the arm comes out through the arm hole between.
- **Tops come up to the arm:** a top (the suit's jacket, the dress's bodice, the robe) rises at his sides to a little
  above the top of the arm where it leaves him (`shouldered` in `src/`), so the sleeve comes out of the top, never
  out of bare body above it.
- **Sleeves:** an outfit with a top (`sleeve: { len, cuff }`: suit 0.6, robe 0.58, dress 0.3) gives his arms
  sleeves. The bot mascot's SVG carries them (`data-sleeve`), and `compose` hands them to every arm it draws: Working,
  Calling, the playground, exports. `drawArm` fills the arm in the cloth from its opening to `len` along it: the
  arm's own drawn outline up to the cuff, closed back across the opening along his outline, so no bare patch of
  arm shows at the root however the edges leave the opening (hanging down his side included). The cloth runs a
  hair (1.5) past the arm's fill so there's no seam where it meets his own clothes, and `compose` fills the
  rounded corners where the arm's edges meet his side (outside both him and the arm) in the cloth too. The arm's
  own shading goes on top. A straight cuff and a seam end it. With no outfit, the arm is unchanged.
  **No scuffing** (Dylan): in
  `compose`, the arm's fill from its opening to the cuff (a hair past it, under the cuff's own stroke) and everything
  its root and armpit add outside him are painted in the cloth under the sleeve's own drawing, so no yellow ever
  shows between the sleeve and his side at any angle; under a sleeve the arm drawing's own base fill is left out
  (the arm's fill already is it; its edge showed as a hairline), and a drape isn't drawn again over a sleeved root
  (its shading made a seam). A garment with its own light (the robe's) lays it out where the garment is and shares
  it with its sleeves (one gradient, `<uid>sl`), so robe and sleeve are one cloth across his side, with no seam.
- **The robe at the lower root** (Dylan: "clean up the other outfits"): a
  deep gold V collar, the sash at his waist (not under the collar, where it read as a second neckline), stars on his
  chest either side of the collar and on the skirt below the sash (clear of the arms' roots), folds below the sash,
  and a hem near the floor (its corners' dangles 80). The suit, dress, tutu and tie already read clearly at the new
  height and are unchanged.
- **The skinny tie** (Dylan: "move the tie down a bit"): knot and blade `TIE_DROP` (16) lower on him, same shape and
  size; its tip now lies over the top of his leg arch, in front of him, rather than just touching it. It's far from
  the arms' roots, and an arm crossing his chest is in front of it.
- **Outfit tops** (Dylan): a top's edge
  (suit, dress, robe; the overalls' bib a touch) is one smooth round curve, lowest in the middle and rising to his
  sides, as if it wraps round him (`shouldered` in `src/`), to `TOP_CLEAR` (12) above the top of the arm where it
  leaves him. The arm's root never moves, so the arm always comes out of the top, never out of bare body above it.
- **Layering with clothes** (Dylan): an arm is never behind his
  clothes. An arm behind something in front of him (Working's reach behind the clipboard, layer `behind`) is drawn
  over his clothes and under the board and its page. The overalls' straps and bib are clothes like any other: the arm
  is drawn in front of them wherever it passes over (Dylan: "straps always above the arms" means their place, higher
  on him than the arm's root, not the drawing order). They sit above the root (see Body zones, Shoulders), so a strap
  passes over his shoulder clear of the arm, and an arm raised over his head or across his chest crosses in front of
  it.
- **Arms over clothes:** arms are always drawn over clothes. The arm's own band over him is kept to the arm,
  so its copy in front of the board never shades the board.

## Depth: the layering model (Dylan's)

Layering comes from one rule set, thought of as depth in 3D, not per-item fixes. Each worn piece has a depth
role, each part of an arm has a depth from where it is, and the order follows from the two.

**Worn pieces, by role** (`role` on the bot mascot's outfits and eyewear):

- **surface:** worn on his body's front, part of it: clothes (shirts, jackets, the overalls), the scarf's
  neck band, the tie's knot, the skirts (tutu, dress, robe).
- **drape:** hangs in front from the neck, over the shoulder and the arm's root: the scarf's tails and the
  tie's blade. Each is a pendulum from its anchor.
- **behind:** goes round behind him: the goggles' strap.
- **cover** (none yet): a surface piece that covers the shoulder itself, like a cape's yoke.

**Arm parts, by where they are:**

- **root:** the part within the root radius of the shoulder pivot (0.8 flipper lengths, scaled with a bud),
  where the arm emerges from his side.
- **front:** the rest, the arm swung out from him or in front of him: across his chest, raised, the throw,
  holding the board.

**The order** (back to front):

1. behind pieces;
2. his body;
3. surface pieces;
4. the arm;
5. drape pieces, wholly over or wholly under each arm (see below);
6. cover pieces, over the arm's root only.

So the arm draws over everything on his body's front and over every drape, except at its root. There, the
drapes (and anything covering the shoulder) lie over it, so it emerges from under them.

**Drapes and arms (Dylan's scarf rule):**

- **One bundle:** a drape's pieces (the scarf's two tails, the tie's blade) move as one bundle: one rigid swing
  about the first piece's anchor.
- **The arm on the drape's side** (the scarf's tails hang on his screen-left):
  - **At rest or holding** (its tip below its shoulder and not out past his side), the arm comes out under the
    tails: they drape over its root.
  - **Once it rises or moves out,** it's outside them. It comes from his side, so it pushes the bundle inward
    (toward his centre, the body side of the arm), by as little as clears it, up to 75°. Then it passes over
    them: never up between the tails, never with them outside it.
  - **Coming back down,** they settle back over its root.
  - **Always over them once it rises** (Dylan): the tails are pushed inward just enough to clear the arm's root and
    join at his side, so nothing of them shows at the shoulder; any of them still under the rest of the arm is
    hidden by it. They're never drawn over a raised arm.
  - **The switch has hysteresis** and only happens while the tails, below the band, are clear of the arm's root.
  - **At rest, over its root**, only the tails are drawn again, masked to the arm's root (in the bot mascot's order; a tail
    behind the band less the band), never the band, which stays under the arm.
- **Any other arm** (the far arm reaching across, any arm and the tie's blade) is in front and draws over the
  drape. The drape only gives way a little (up to 30°, away from it).
- **Occlusion (line art):** the occluded piece's line stops where it passes under the occluder's fill, and the
  occluder's line runs on over it. An arm in front is drawn whole over everything at its layer (fill and line), so
  that holds for his outline, clothes and drapes alike.
- **No narrow crossings:** pushed inward, the tails swing on a little further (up to 40°, never past level) until
  no tail's edge meets the arm's edge at under 35° (a tail touching the arm's root always counts as narrow). Each
  tail either clears the arm, lies wholly under it, or crosses its edge squarely.
- **Outline over a drape:** wherever an arm lies over a drape, its line is there as everywhere. Where the drape is
  over the arm, the drape layer as drawn is drawn again over the arm.
- **The swing** is a damped spring per drape. In a still it's simply where it settles.

**Where it lives:**

- **The bot mascot** (`src/`) gives each drape piece an id (`<uid>dt0`, `<uid>dt1`, …). `redrape(uid, arms)`
  takes the arms (side, pivot, spine points marked root or front, the tip's distance out past his outline), keeps
  each arm's state and the bundle's swing, and draws the drape again.
- **The rig's `compose`** hands it the arms. For an arm the drape is over, it draws the drape layer again over
  that arm, masked to the arm's shape and outline. For the others, it outlines the arm where it lies over the
  drape.
- Every arm (Working, Calling, the playground, exports) goes through `compose`, so the order is the same
  everywhere.
