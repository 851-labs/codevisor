import {
  FALL_ASLEEP,
  SLEEP_LOOP,
  SLEEP_Z_COUNT,
  sleepZs,
  zStroke,
  Z_FADE_IN,
  Z_FADE_OUT
} from "../../src/animations/sleeping.js"
import { SLEEP_Z_CORE_WIDTH, SLEEP_Z_INK_WIDTH } from "../../src/effects/effects.js"
import { f, newId } from "./emit.js"
import { after, go, modeIs, type StateRefs } from "./moves.js"
import { add, tracksXml, type Tracks } from "./tracks.js"

export interface ZInk {
  readonly outline: string
  readonly outlineBind: string
  readonly core: string
  readonly coreBind: string
}

interface ZIds {
  readonly shape: string
  readonly vertices: ReadonlyArray<string>
}

const Z_CORNERS = 4
const zIds: ReadonlyArray<ZIds> = Array.from({ length: SLEEP_Z_COUNT }, () => ({
  shape: newId(),
  vertices: Array.from({ length: Z_CORNERS }, () => newId())
}))
const zzzAnimation = newId()
const noZsAnimation = newId()
const drowsyAnimation = newId()
const asleepState = newId()
const drowsyState = newId()
const awakeState = newId()

export function sleepZsXml(ink: ZInk): string {
  const rest = sleepZs(0, 1)
  const shapes = zIds.map((ids, i) => {
    const corners = zStroke(rest[i])
      .map(([x, y], k) => `<StraightVertex x="${f(x)}" y="${f(y)}" id="${ids.vertices[k]}"/>`)
      .join("")
    const strokes =
      zStrokeXml("Ink", SLEEP_Z_INK_WIDTH, ink.outline, ink.outlineBind) +
      zStrokeXml("Core", SLEEP_Z_CORE_WIDTH, ink.core, ink.coreBind)
    return `<Shape opacity="0" name="Z ${i + 1}" id="${ids.shape}"><PointsPath isClosed="false" name="Path">${corners}</PointsPath>${strokes}</Shape>`
  })
  return `<Node name="Sleep Zs" id="${newId()}">${shapes.join("")}</Node>`
}

export function sleepZsAnimationsXml(): string {
  const frames = Math.round(SLEEP_LOOP * 60)
  const floating: Tracks = new Map()
  for (let frame = 0; frame <= frames; frame++) keyZs(floating, frame / 60 - Z_FADE_IN, frame)
  const hidden: Tracks = new Map()
  for (const ids of zIds) add(hidden, ids.shape, "opacity", 0, 0)
  const drowsyFrames = Math.round((FALL_ASLEEP - Z_FADE_IN) * 60)
  return (
    `<LinearAnimation duration="${frames}" loopValue="loop" name="sleep zs" id="${zzzAnimation}">${tracksXml(floating)}</LinearAnimation>\n` +
    `<LinearAnimation duration="1" name="no sleep zs" id="${noZsAnimation}">${tracksXml(hidden)}</LinearAnimation>\n` +
    `<LinearAnimation duration="${drowsyFrames}" name="drowsy, no zs yet" id="${drowsyAnimation}">${tracksXml(hidden)}</LinearAnimation>`
  )
}

export function sleepZsLayer(r: StateRefs): string {
  const sleeping = r.modeValues.sleeping
  const dozing = go(drowsyState, 0, modeIs(r, sleeping))
  const fadeIn = after(asleepState, Z_FADE_IN * 1000)
  const wokeEarly = go(awakeState, 0, modeIs(r, sleeping, "notEqual"))
  const fadeOut = go(awakeState, Z_FADE_OUT * 1000, modeIs(r, sleeping, "notEqual"))
  return `<StateMachineLayer name="Sleep Zs" id="${newId()}"><AnyState x="60" y="-120"/><ExitState x="900" y="-120"/><EntryState x="60" y="0"><StateTransition stateToId="${awakeState}"/></EntryState>
<AnimationState animationId="${noZsAnimation}" x="260" y="0" id="${awakeState}">${dozing}</AnimationState>
<AnimationState animationId="${drowsyAnimation}" x="480" y="0" id="${drowsyState}">${wokeEarly}${fadeIn}</AnimationState>
<AnimationState animationId="${zzzAnimation}" x="700" y="0" id="${asleepState}">${fadeOut}</AnimationState>
</StateMachineLayer>`
}

const zStrokeXml = (name: string, width: number, color: string, bind: string): string =>
  `<Stroke thickness="${width}" cap="round" join="round" name="${name}"><SolidColor colorValue="${color}" name="C">${bind}</SolidColor></Stroke>`

function keyZs(tracks: Tracks, asleep: number, frame: number) {
  sleepZs(asleep, 1).forEach((z, i) => {
    const ids = zIds[i]
    add(tracks, ids.shape, "opacity", frame, z.op)
    zStroke(z).forEach(([x, y], k) => {
      add(tracks, ids.vertices[k], "x", frame, x)
      add(tracks, ids.vertices[k], "y", frame, y)
    })
  })
}
