import { callSeconds } from "../../src/animations/calling-segments.js"
import type { Matrix } from "../../src/arms/arm-pose.js"
import { CLIPBOARD_LOOP } from "../../src/effects/clipboard.js"
import { keyArms, restArmKeys, type ArmKeyIds } from "./arm-keys.js"
import { newId } from "./emit.js"
import { sample, type Sample, type Segment } from "./motion.js"
import { pageAt } from "./props.js"
import { restTargets, shoulderTargets } from "./skinning.js"
import { pathContours } from "./svg.js"
import { add, keyVertex, tracksXml, type Tracks } from "./tracks.js"

export interface MoveIds extends ArmKeyIds {
  readonly bodyVertices: ReadonlyArray<string>
  readonly character: string
  readonly shadow: string
  readonly shadowSquash: number
  readonly lean: string
  readonly remaps: Readonly<
    Record<"wanderMid" | "wanderUp" | "wanderDown" | "blink" | "annoyed" | "mad", string>
  >
  readonly phone: string
  readonly clipboard: string
  readonly page: Readonly<
    Record<
      "rising" | "hanging",
      {
        readonly shape: string
        readonly dim: string
        readonly vertices: ReadonlyArray<string>
        readonly dimVertices: ReadonlyArray<string>
      }
    >
  >
}

export interface Move {
  readonly segment: Segment
  readonly seconds: number
  readonly loops: boolean
  readonly animation: string
  readonly props: string
}

const SWING = 0.65

export const moves: ReadonlyArray<Move> = [
  { segment: "startWorking", seconds: SWING, loops: false, animation: newId(), props: newId() },
  { segment: "working", seconds: CLIPBOARD_LOOP, loops: true, animation: newId(), props: newId() },
  { segment: "stopWorking", seconds: SWING, loops: false, animation: newId(), props: newId() },
  {
    segment: "pickUp",
    seconds: callSeconds.pickUp,
    loops: false,
    animation: newId(),
    props: newId()
  },
  {
    segment: "calling",
    seconds: callSeconds.calling,
    loops: true,
    animation: newId(),
    props: newId()
  },
  {
    segment: "hangUp",
    seconds: callSeconds.hangUp,
    loops: false,
    animation: newId(),
    props: newId()
  },
  {
    segment: "angryHangUp",
    seconds: callSeconds.angryHangUp,
    loops: false,
    animation: newId(),
    props: newId()
  }
]

const rad = (deg: number | undefined) => ((deg ?? 0) * Math.PI) / 180
const clamp01 = (v: number) => Math.max(0, Math.min(1, v))

function keyBody(tracks: Tracks, ids: MoveIds, s: Sample, frame: number) {
  const p = s.pose
  const sy = p.sy ?? 1
  const lift = p.y ?? 0
  const shadow = Math.max(0.25, 1 - lift / 280)
  add(tracks, ids.character, "rotation", frame, rad(p.lean))
  add(tracks, ids.character, "scaleX", frame, 2 - sy)
  add(tracks, ids.character, "scaleY", frame, sy)
  add(tracks, ids.character, "y", frame, 412 - lift)
  add(tracks, ids.shadow, "scaleX", frame, shadow * (2 - sy))
  add(tracks, ids.shadow, "scaleY", frame, shadow * ids.shadowSquash)
  add(tracks, ids.shadow, "opacity", frame, shadow)
  add(tracks, ids.lean, "rotation", frame, rad(p.tilt))
}

function keyShoulders(tracks: Tracks, ids: MoveIds, s: Sample, frame: number) {
  for (const target of shoulderTargets(s.pose, s.body))
    keyPoint(tracks, ids.bodyVertices[target.index], target.p, frame)
}

const keyPoint = (tracks: Tracks, id: string, p: readonly [number, number], frame: number) => {
  add(tracks, id, "x", frame, p[0])
  add(tracks, id, "y", frame, p[1])
}

function keyFace(tracks: Tracks, ids: MoveIds, s: Sample, frame: number) {
  const face = s.pose.face ?? {}
  const turn = ((face.turn ?? 0) + 1) / 2
  const up = face.up ?? 0
  add(tracks, ids.remaps.wanderMid, "time", frame, turn)
  add(tracks, ids.remaps.wanderUp, "time", frame, turn)
  add(tracks, ids.remaps.wanderDown, "time", frame, turn)
  add(tracks, ids.remaps.wanderUp, "mix", frame, Math.max(0, -up))
  add(tracks, ids.remaps.wanderDown, "mix", frame, Math.max(0, up))
  add(tracks, ids.remaps.blink, "time", frame, clamp01((1 - (face.blink ?? 1)) / 0.92))
  const mad = face.mode === "mad"
  add(tracks, ids.remaps.annoyed, "time", frame, mad ? 0 : clamp01((face.brow ?? 0) / 22))
  add(tracks, ids.remaps.mad, "time", frame, mad ? 1 : 0)
}

function keyPlacement(tracks: Tracks, id: string, m: Matrix | null, frame: number) {
  add(tracks, id, "opacity", frame, m ? 1 : 0)
  if (!m) return
  const sx = Math.hypot(m[0], m[1])
  add(tracks, id, "x", frame, m[4])
  add(tracks, id, "y", frame, m[5])
  add(tracks, id, "rotation", frame, Math.atan2(m[1], m[0]))
  add(tracks, id, "scaleX", frame, sx)
  add(tracks, id, "scaleY", frame, sx > 1e-6 ? (m[0] * m[3] - m[1] * m[2]) / sx : 0)
}

function keyPage(tracks: Tracks, ids: MoveIds, s: Sample, frame: number) {
  const tt = s.board?.flip ?? 0
  const page = pageAt(tt)
  for (const kind of ["rising", "hanging"] as const) {
    const shown = !!s.board && page.visible && page.rising === (kind === "rising")
    const ref = ids.page[kind]
    add(tracks, ref.shape, "opacity", frame, shown ? 1 : 0)
    add(tracks, ref.dim, "opacity", frame, shown ? page.dim : 0)
    if (!shown) continue
    const vs = pathContours(page.d)[0]?.vertices ?? []
    vs.forEach((v, i) => {
      keyVertex(tracks, ref.vertices[i], v, frame)
      keyVertex(tracks, ref.dimVertices[i], v, frame)
    })
  }
}

function animationXml(move: Move, ids: MoveIds): string {
  const frames = Math.round(move.seconds * 60)
  const face: Tracks = new Map()
  const props: Tracks = new Map()
  for (let frame = 0; frame <= frames; frame++) {
    const s = sample(move.segment, Math.min(move.seconds - 1e-6, frame / 60))
    keyBody(props, ids, s, frame)
    keyShoulders(props, ids, s, frame)
    keyFace(face, ids, s, frame)
    keyArms(props, ids, s, frame)
    keyPlacement(props, ids.phone, s.phone, frame)
    keyPlacement(props, ids.clipboard, s.board?.matrix ?? null, frame)
    keyPage(props, ids, s, frame)
  }
  const loop = move.loops ? ` loopValue="loop"` : ""
  const timeline = (name: string, id: string, tracks: Tracks) =>
    `<LinearAnimation duration="${frames}"${loop} name="${name}" id="${id}">${tracksXml(tracks)}</LinearAnimation>`
  return (
    timeline(move.segment, move.animation, face) +
    "\n" +
    timeline(`${move.segment} props`, move.props, props)
  )
}

export const movesXml = (ids: MoveIds): string => moves.map((m) => animationXml(m, ids)).join("\n")

export function restKeys(ids: MoveIds): string {
  const tracks: Tracks = new Map()
  add(tracks, ids.remaps.annoyed, "time", 0, 0)
  add(tracks, ids.remaps.mad, "time", 0, 0)
  add(tracks, ids.shadow, "opacity", 0, 1)
  add(tracks, ids.shadow, "scaleY", 0, ids.shadowSquash)
  add(tracks, ids.character, "y", 0, 412)
  return tracksXml(tracks)
}

export const idleProps = newId()

export function idlePropsXml(ids: MoveIds): string {
  const tracks: Tracks = new Map()
  restArmKeys(tracks, ids)
  for (const target of restTargets()) keyPoint(tracks, ids.bodyVertices[target.index], target.p, 0)
  add(tracks, ids.phone, "opacity", 0, 0)
  add(tracks, ids.clipboard, "opacity", 0, 0)
  for (const kind of ["rising", "hanging"] as const) {
    add(tracks, ids.page[kind].shape, "opacity", 0, 0)
    add(tracks, ids.page[kind].dim, "opacity", 0, 0)
  }
  return `<LinearAnimation duration="1" name="idle props" id="${idleProps}">${tracksXml(tracks)}</LinearAnimation>`
}

interface StateRefs {
  readonly vm: string
  readonly mode: string
  readonly modeValues: Readonly<Record<"idle" | "working" | "calling", string>>
  readonly hangUp: string
  readonly angryHangUp: string
  readonly idleState: string
}

const modeIs = (r: StateRefs, value: string, op = "equal") =>
  `<TransitionViewModelCondition opValue="${op}"><TransitionPropertyViewModelComparator><BindablePropertyEnum><DataBindContext sourcePathIds="${r.vm}-${r.mode}" propertyKey="637"/></BindablePropertyEnum></TransitionPropertyViewModelComparator><TransitionValueEnumComparator value="${value}"/></TransitionViewModelCondition>`
const fired = (r: StateRefs, prop: string) =>
  `<TransitionViewModelCondition><TransitionPropertyViewModelComparator><BindablePropertyTrigger><DataBindContext sourcePathIds="${r.vm}-${prop}" propertyKey="686"/></BindablePropertyTrigger></TransitionPropertyViewModelComparator><TransitionValueTriggerComparator/></TransitionViewModelCondition>`
const go = (to: string, ms: number, conditions = "") =>
  `<StateTransition stateToId="${to}" duration="${ms}">${conditions}</StateTransition>`
const after = (to: string, ms = 0) =>
  `<StateTransition stateToId="${to}" duration="${ms}" enableExitTime="true" exitTimeIsPercetange="true" exitTime="100"/>`

export interface Layer {
  readonly idle: string
  readonly idleState: string
  readonly animation: (move: Move) => string
  readonly blend: (ms: number) => number
}

const bodyAnimation = (m: Move): string => m.animation
const propsAnimation = (m: Move): string => m.props
const asIs = (ms: number): number => ms
const instant = (): number => 0

export function bodyLayer(r: StateRefs, idleBlend: string): string {
  const idleState = r.idleState
  return layerStates(r, { idle: idleBlend, idleState, animation: bodyAnimation, blend: asIs })
}

export interface PropsLayer {
  readonly idleState: string
  readonly xml: string
}

export function propsLayer(r: StateRefs): PropsLayer {
  const idleState = newId()
  const idle = `<AnimationState animationId="${idleProps}" x="260" y="0" id="${idleState}"><!--transitions--></AnimationState>`
  const xml = layerStates(r, { idle, idleState, animation: propsAnimation, blend: instant })
  return { idleState, xml }
}

function layerStates(r: StateRefs, layer: Layer): string {
  const ids = new Map(moves.map((m) => [m.segment, newId()]))
  const anims = new Map(moves.map((m) => [m.segment, layer.animation(m)]))
  const id = (segment: Segment): string => ids.get(segment) ?? ""
  const ms = layer.blend
  const state = (segment: Segment, x: number, y: number, transitions: string) =>
    `<AnimationState animationId="${anims.get(segment) ?? ""}" x="${x}" y="${y}" id="${id(segment)}">${transitions}</AnimationState>`
  const idle = layer.idle.replace(
    "<!--transitions-->",
    go(id("startWorking"), ms(250), modeIs(r, r.modeValues.working)) +
      go(id("pickUp"), ms(250), modeIs(r, r.modeValues.calling))
  )
  return [
    idle,
    state("startWorking", 520, -200, after(id("working"))),
    state(
      "working",
      780,
      -200,
      go(id("stopWorking"), ms(250), modeIs(r, r.modeValues.working, "notEqual"))
    ),
    state("stopWorking", 520, -320, after(layer.idleState, ms(200))),
    state("pickUp", 520, 200, after(id("calling"))),
    state(
      "calling",
      780,
      200,
      go(id("angryHangUp"), ms(250), fired(r, r.angryHangUp)) +
        go(id("hangUp"), ms(250), fired(r, r.hangUp)) +
        go(id("hangUp"), ms(250), modeIs(r, r.modeValues.calling, "notEqual"))
    ),
    state("hangUp", 520, 340, after(layer.idleState, ms(200))),
    state("angryHangUp", 780, 340, after(layer.idleState, ms(200)))
  ].join("\n")
}
