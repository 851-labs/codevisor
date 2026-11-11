# @codevisor/bot-mascot

The Codevisor bot mascot: a single-shape character built from the Codevisor logo, drawn as SVG. It has
eighteen body colors, hats, eyewear, outfits, makeup, a cyclops eye that looks round his face, arms on a rig,
and animated moods. This package holds all of it: the geometry and palettes, the drawing, the animation
logic, the arm rig, a Rive version of the character and the scripts that generate it.

## Rendering a still

```ts
import { botMascotColors, botMascotHats, renderBotMascotSvg } from "@codevisor/bot-mascot"

const svg = renderBotMascotSvg({ color: "mint", hat: "beanie", eyewear: "specs" })
```

`renderBotMascotSvg(options)` is pure: the same options always give the same SVG string. Every option is
optional.

| Option                                        | Values                                                                                 |
| --------------------------------------------- | -------------------------------------------------------------------------------------- |
| `color`                                       | `botMascotColors` ids, default `"sunny"`                                               |
| `hat`, `eyewear`, `outfit`                    | `botMascotHats`, `botMascotEyewear`, `botMascotOutfits` ids, or `"none"`               |
| `hatColor`, `eyewearColor`, `outfitColor`     | `"auto"` (the designed default) or one of the item's `swatches`                        |
| `makeup`, `blushColor`                        | `{ blush, freckles, lashes }` (blush is on by default), `"auto"` or a swatch           |
| `mood`                                        | `botMascotMoodOptions` ids, default `"idle"`; drawn at the mood's still                |
| `size`, `viewBox`, `backdrop`, `uid`, `zones` | pixel size, framing (a portrait by default), `"white"` backdrop, id prefix, body zones |

`working` and `calling` grow his arms (Working holds a clipboard, Calling a phone). A choice an item doesn't
offer falls back to its default. Give each SVG on a page its own `uid`: every id in it starts with it.

Each option list (`botMascotColors`, `botMascotHats`, `botMascotEyewear`, `botMascotOutfits`,
`botMascotMakeup`, `botMascotMoodOptions`, `botMascotSwatches`) has ids and titles for a picker; items list
their swatches and whether they have an Auto color. `randomBotMascotConfig(random)` picks a random look the
way the original builder's Randomize did.

## Animating

`BotMascotPlayer` is the builder's live stage without the DOM. Call `frame(nowMs)` every frame and put the
SVG on screen; `update(config, nowMs)` changes his look or mood. It plays Idle, Working and Calling and the
transitions between them (arms growing out and tucking away, picking up and calmly hanging up), drops a new hat on his
head, fades new clothes in and swings a tie or skirt on its pendulums. Pass `reducedMotion: true` for still
frames. `request(request, nowMs)` takes the same requests as `botMascotRoute` below, so
`request("angryHangUp", nowMs)` ends a call by throwing the phone; changing the mood away from calling hangs up
normally. `mountBotMascot(element)` writes frames into an element, rewriting only what changed.

### Segments

Idle is the hub: every animation starts from idle and returns to it. `botMascotSegments` names each part
and the state it goes from and to:

| Segment        | From → to         | What he does                                           |
| -------------- | ----------------- | ------------------------------------------------------ |
| `idle`         | idle → idle       | the resting loop                                       |
| `pickUp`       | idle → calling    | the phone pops in, he grabs it and lifts it to his ear |
| `calling`      | calling → calling | talks on the phone; loops cleanly                      |
| `hangUp`       | calling → idle    | says bye, lowers the phone, puts it away and settles   |
| `angryHangUp`  | calling → idle    | gets annoyed, yells, throws the phone and huffs it off |
| `startWorking` | idle → working    | grows his arms and pops out the clipboard              |
| `working`      | working → working | reads the clipboard and flips its page                 |
| `stopWorking`  | working → idle    | tucks the clipboard and his arms away                  |

`botMascotRoute(state, request)` gives the chain for a request (`"idle"`, `"calling"`, `"working"`,
`"hangUp"`, `"angryHangUp"`): from calling, `"working"` is `["hangUp", "startWorking", "working"]`.
`canFollow(a, b)` says whether one segment may follow another. `botMascotSequence(steps)` lays a chain out in
time (a loop step takes a `seconds`) and `at(t)` gives the `SegmentFrame` to pass to
`renderBotMascotSegmentFrame`. The frame's `clock` drives the idle underneath, so a chain stays continuous;
`soloFrame(segment, t)` plays one segment on its own. A call step that stops mid-cycle sets the next frame's
`leftCallAt`, and the hang-up eases out of that moment of the call over its first 0.35 s. Segments that leave idle start on the idle frame, and
segments that return to it end on it.

### Looking at a point

Idle can look at a target in the mascot's own coordinates (the 500 × 500 scene his `viewBox` frames). Pass
`gaze: { x, y, weight? }` to `renderBotMascotSegmentFrame`, or call `player.lookAt([x, y])` and
`player.lookAt(null)`. His eye, and any eyewear, turn toward the target, his head tilts and twists a little,
and he keeps breathing and blinking; working and calling ignore it, but the idle they leave from and return
to looks too, so the seams hold. `GAZE_RANGE` limits how far he looks (a turn of 0.8, up 0.55, down 0.45,
easing out over about 170 px across and 150 px up and down). `gazeFollower()` springs a raw pointer into a
gaze (`GAZE_EASING`): it follows at 2.4 Hz and engages over about half a second, and once the target is
gone, or hasn't moved for 2.5 s, it drifts back to centre and hands back to idle over about two seconds. With
no gaze, idle draws exactly as it always has.

Lower down, `botMascotMoods` gives every mood's pose over time (idle, working, calling) and `renderBotMascotFrame` draws any pose. The arm rig (`poseArm`, `drawRig`,
`composeArms`, `phoneProp`) puts an arm's tip on any target; `renderIdleWorking` and `renderCallingSwap` are
Working and Calling with his arms. `hatRider` and `dangle` are the springs behind a hat and a dangling hem.
`docs/arm-rig.md`, `docs/arm-spec.md` and `docs/shading.md` explain the arm rig and the one light.

## Playground

`bun run dev:mascot-playground` opens `apps/mascot-playground`, which shows the Rive character (Outfit,
Animation and Compare against today's renderer), and keeps the developer tools below under Advanced. It draws this package from `src/` with
hot reload: every outfit, every animation segment (play, pause, scrub, speed, loop), the arm rig's pose with debug
overlays, the app's sidebar figure and circle avatar at 1×, 2× and 3×, and PNG and SVG export. Its URL holds
the whole state, so a link opens the same look, animation and frame.

## Layout

```
src/
  render-static.ts, config.ts, options.ts, player.ts   the public API
  data/bot-mascot-data.json                             geometry and palettes (generated, see below)
  body/          zones (his height) and the pose rig that bends his outline
  face/          the eye, glints, lashes, makeup and eyewear
  hats/          hats and the hat's spring
  outfits/       clothes clipped to his body
  drapes/        ties and skirts that hang off him, and how they give way to an arm
  effects/       floating hands, the clipboard and the phone
  moods/         every mood's timeline and blending between moods
  arms/          the arm rig: reach, drawing, the union with his body, props; and the flipper study
  animations/    Working and Calling with his arms
  render/        the frame renderer and the DOM mount
rive/
  bot-mascot/    the Rive project (artboard, state machine and view model "Bot Mascot")
  tools/         the Rive scene generator and the data export
docs/            the arm rig, its rules and the shading
```

## The Rive character

`rive/mascot/` is the Rive project the apps are moving to (851-3991), and its RML is the source of truth:
edit `1-character.rml`, `2-face.rml` and `3-data.rml` directly, then build with the Rive CLI
1.8.0. The build needs no Rive login and is byte-for-byte reproducible. It writes `resources/mascot.riv`,
which is checked in and which the server serves to the apps. Use 1.8.0: from 1.9.0 the CLI drops `--once`,
and its `--publish` watermarks a project that isn't bound to a file in a Rive account.

```bash
mkdir -p /tmp/rive-cli-1.8.0
curl -fsSL https://releases.rive.app/cli/v1.8.0/rive-macos-arm64.tar.gz | tar xz -C /tmp/rive-cli-1.8.0
/tmp/rive-cli-1.8.0/rive packages/bot-mascot/rive/mascot --once
```

The artboard `Bot Mascot` and state machine `Bot Mascot` use the view model `BotMascot`:

| Property                                                           | Meaning                                                    |
| ------------------------------------------------------------------ | ---------------------------------------------------------- |
| `mode`                                                             | enum: `idle`, `working` or `calling`                       |
| `hangUp`, `angryHangUp`                                            | triggers that end a call                                   |
| `hat`, `outfit`                                                    | enums: `none` or an item id                                |
| `body0…`, `hat0…`, `outfit0…`                                      | color slots for the body, the hat and the outfit           |
| `gazeX`, `gazeY`, `gazeWeight`                                     | the look direction (-1 to 1, already eased) and its weight |
| `face/eyewear`                                                     | enum: `none` or an eyewear id                              |
| `face/lashesOn`, `face/blushOn`, `face/frecklesOn`                 | 0 or 1                                                     |
| `face/face0…`, `face/blush0…`, `face/freckles0…`, `face/eyewear0…` | color slots for the face parts                             |

`riveValues(config)` turns a look into those values, using `src/data/rive-colors.json` (every item × color
choice × body color, so a host never computes colors). The face is the nested `Face` artboard: three row
timelines (looking up, ahead and down), scrubbed by turn and mixed by how far up or down he looks. Idle
blends two timelines. `Idle look` (his own glances and lean) fades out as `gazeWeight` rises, and blinks
keep going.

`mode` moves him from idle into Working or Calling and back. Fire `hangUp` or `angryHangUp` to end a call,
and set `mode` back to `idle` with it. The state machine has two layers: `Face` blends between moves so his
eye and gaze never jump, and `Body` switches his pose, arms, phone and clipboard at once, so the arms always
fit the body they were baked against. His arms and shoulders are baked from the TypeScript compositor. Each
arm is one path with its outline drawn as trimmed strokes. During moves the body's outline around the
shoulders is keyed to the TypeScript body, so the arms fit it exactly, and a join shape redraws the merged
body-and-arm silhouette, fillets included, wherever an arm pushes past the body. Grow and collapse are
keyed every frame and the rest every other frame. A draw rule moves the right arm behind the clipboard or
between its pages, and outfits with sleeves get clipped sleeves.

`rive/bootstrap/` generated the first version of these files once, from the TypeScript renderer
(`bun packages/bot-mascot/rive/bootstrap/build.ts`). It's kept as a record until the TypeScript renderer is
retired. Rerunning it overwrites any hand edits.

A body color is data, not art: `mascot.riv` reads every color from its view model, so adding one needs no
Rive build. Add its palette to `rive/tools/palettes.py` and run `export_data.py` (below), add its id to
`botMascotColorIds` (picker order) and `botMascotColorRotation` (the order new bots get), give it a hat, denim
and phone color in `color/colors.ts` and `effects/handset.ts`, then regenerate the color table with
`bun packages/bot-mascot/rive/bootstrap/colors-file.ts`. Keep its outline and eye the same color, as every
palette does, so it fills the Rive file's existing color slots.

The editor round trip is optional and needs a Rive account. Run `rive login` once, then `rive pull` or
`rive push` from `rive/mascot/`. A pull may renumber ids.

`rive/bot-mascot/` and `rive/tools/` are the earlier Rive character and the Python scripts. They also export
`src/data/bot-mascot-data.json`:

```bash
python3 packages/bot-mascot/rive/tools/export_data.py && bun run format
```

## Origin

This was the "Pip" character in the standalone mascot repo, ported to TypeScript. The tests pin the
drawing to the original builder's output for a range of looks and moods, so a change that moves a single
point fails them.
