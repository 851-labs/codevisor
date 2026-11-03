# @codevisor/bot-mascot

The Codevisor bot mascot: a single-shape character built from the Codevisor logo, drawn as SVG. It has
eight body colors, hats, eyewear, outfits, makeup, a cyclops eye that looks round his face, arms on a rig,
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
transitions between them (arms growing out and tucking away, the phone popping away), drops a new hat on his
head, fades new clothes in and swings a tie or skirt on its pendulums. Pass `reducedMotion: true` for still
frames. `mountBotMascot(element)` writes frames into an element, rewriting only what changed.

Lower down, `botMascotMoods` gives every mood's pose over time (idle, happy, sad, sleepy, surprised,
thinking, working, calling) and `renderBotMascotFrame` draws any pose. The arm rig (`poseArm`, `drawRig`,
`composeArms`, `phoneProp`) puts an arm's tip on any target; `renderIdleWorking` and `renderCallingSwap` are
Working and Calling with his arms. `hatRider` and `dangle` are the springs behind a hat and a dangling hem.
`docs/arm-rig.md`, `docs/arm-spec.md` and `docs/shading.md` explain the arm rig and the one light.

## Playground

`bun run dev:mascot-playground` opens `apps/mascot-playground`, which draws this package from `src/` with
hot reload: every outfit, every animation (play, pause, scrub, speed, loop), the arm rig's pose with debug
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
  effects/       floating hands, sparkles, tears, the clipboard, the phone and the thought cloud
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

`rive/bot-mascot/scene.rml` is generated. Its view model `BotMascot` has `mood` (enum `BotMascotMood`:
idle, thinking, happy, sad, sleeping, surprised), `wave` (a trigger: a lean-and-hop hello, also fired by a
tap) and `shadow` (the ground shadow). The scripts need only Python 3:

```bash
python3 packages/bot-mascot/rive/tools/bot_mascot.py
rive packages/bot-mascot/rive/bot-mascot --verify
```

`bot_mascot.py` takes `--palette=<color>` and `--backdrop[=ARGB]` (preview captures only).

`src/data/bot-mascot-data.json` comes from the same vertices, so the SVG and the Rive file match:

```bash
python3 packages/bot-mascot/rive/tools/export_data.py && bun run format
```

## Origin

This was the "Pip" character in the standalone mascot repo, ported to TypeScript. The tests pin the
drawing to the original builder's output for a range of looks and moods, so a change that moves a single
point fails them.
