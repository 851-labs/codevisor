import { phoneLeaving } from "../../src/animations/calling-exit.js"
import {
  FLING,
  followThrough,
  phoneFlight,
  RELEASE,
  STILL_PHONE,
  TUCK,
  warp,
  WIND
} from "../../src/animations/calling-flight.js"
import { PICKED_UP, pickUpScene } from "../../src/animations/calling-ground.js"
import { callShot, type CallSegment } from "../../src/animations/calling-segments.js"
import {
  originalCalling,
  phoneScene,
  type OriginalCalling
} from "../../src/animations/calling-swap.js"
import { armsFrameState, type ArmsFrameState } from "../../src/animations/idle-working.js"
import { apply, invert, multiply, parseTransform, placement } from "../../src/animations/matrix.js"
import { fallingAsleep, sleepPose, wakingUp } from "../../src/animations/sleeping.js"
import { flipState, holdPoint, type CarryLayer } from "../../src/animations/working-flip.js"
import { poseArm, type Matrix, type PosedArm } from "../../src/arms/arm-pose.js"
import type { RigArm, Torso } from "../../src/arms/rig-arm.js"
import { phoneProp } from "../../src/arms/rig-draw.js"
import { clipboardPopScale } from "../../src/effects/clipboard.js"
import { lerp2, smootherstep, type Point } from "../../src/geometry/math.js"
import { idleAt } from "../../src/moods/moods.js"
import type { BotMascotPose } from "../../src/pose.js"
import { renderContext, withHands } from "../../src/render/context.js"
import { renderFrame } from "../../src/render/frame.js"
import { svgBody, svgTransform } from "../../src/render/svg-parts.js"

type SleepSegment = "fallAsleep" | "sleeping" | "wakeUp"

export type Segment = CallSegment | SleepSegment | "startWorking" | "working" | "stopWorking"

export interface ArmSample {
  readonly arm: RigArm
  readonly layer: CarryLayer
  readonly hand: number
}

export interface Sample {
  readonly pose: BotMascotPose
  readonly body: string
  readonly arms: Readonly<Record<"left" | "right", ArmSample | null>>
  readonly phone: Matrix | null
  readonly board: { readonly matrix: Matrix; readonly flip: number; readonly page: number } | null
}

interface Scene {
  arm: PosedArm | null
  flying: string
}

const PAL = "sunny"
const SWING = 0.65
const VIEW = "0 0 500 500"
const FLYING = /matrix\(([^)]+)\)/
const BOARD_CENTRE: Point = [250, 350]
const tipsAtRelease = new Map<string, Point>()

export const tfMatrix = (pose: BotMascotPose): Matrix => {
  const sy = pose.sy ?? 1
  return parseTransform(
    `translate(250 ${412 - (pose.y ?? 0)}) rotate(${pose.lean ?? 0}) scale(${2 - sy} ${sy}) translate(-250 -412)`
  )
}

export function sample(segment: Segment, t: number): Sample {
  if (segment === "startWorking" || segment === "working" || segment === "stopWorking")
    return workingSample(segment, t)
  if (segment === "fallAsleep" || segment === "sleeping" || segment === "wakeUp")
    return sleepSample(sleepPoses[segment](t))
  return callingSample(segment, t)
}

const sleepPoses: Readonly<Record<SleepSegment, (t: number) => BotMascotPose>> = {
  fallAsleep: (t) => fallingAsleep(t, idleAt(t)),
  sleeping: (t) => sleepPose(t),
  wakeUp: (t) => wakingUp(t, 0, idleAt(t))
}

function sleepSample(pose: BotMascotPose): Sample {
  const s = renderFrame(renderContext(), PAL, pose, { viewBox: VIEW, uid: "z" })
  return { pose, body: svgBody(s), arms: { left: null, right: null }, phone: null, board: null }
}

function workingSample(segment: Segment, t: number): Sample {
  const since = segment === "startWorking" ? 0 : SWING
  const out = segment === "stopWorking" ? 0 : Infinity
  return workingFrom(armsFrameState(t, { in: -since, out, swing: SWING }), t)
}

function workingFrom(st: ArmsFrameState, t: number): Sample {
  const pose = st.pose
  const fx = pose.fx?.[0]
  const s = renderFrame(
    withHands(renderContext(), () => ""),
    PAL,
    pose,
    { viewBox: VIEW, uid: "w" }
  )
  const board =
    fx && fx.kind === "clipboard"
      ? { k: clipboardPopScale(fx.pop), ny: 1.5 * fx.nod - (pose.y ?? 0), tt: fx.tt }
      : null
  const torso: Torso = { d: svgBody(s), shoulderY: renderContext().body.shoulderY }
  if (!board || st.tw === null)
    return { pose, body: torso.d, arms: { left: null, right: null }, phone: null, board: null }
  const tt = st.tw >= 0.4 ? (st.tw - 0.4) % 12 : -1
  const fl = tt >= 0 ? flipState(tt) : { f: 0 }
  const onBoard = ([x, y]: Point): Point => boardToBody([x, y + board.ny], pose)
  const arm = (side: number): ArmSample | null => {
    const flips = side > 0 && fl.f > 0 && fl.target !== undefined
    const target =
      flips && fl.target ? lerp2(holdPoint(side), fl.target, Math.min(1, st.w)) : holdPoint(side)
    const p = poseArm(torso, { side, grow: st.w, target: onBoard(target), t })
    const layer = flips ? (fl.layer ?? "front") : "front"
    return p?.arm ? { arm: p.arm, layer, hand: 0 } : null
  }
  const world: Matrix = [
    board.k,
    0,
    0,
    board.k,
    BOARD_CENTRE[0] * (1 - board.k),
    BOARD_CENTRE[1] + board.ny - BOARD_CENTRE[1] * board.k
  ]
  return {
    pose,
    body: torso.d,
    arms: { left: arm(-1), right: arm(1) },
    phone: null,
    board: { matrix: multiply(invert(tfMatrix(pose)), world), flip: board.tt, page: board.k }
  }
}

function boardToBody(p: Point, pose: BotMascotPose): Point {
  const sy = pose.sy ?? 1
  const sx = 2 - sy
  const lift = pose.y ?? 0
  return [250 + (p[0] - 250) / sx, 412 + (p[1] - (412 - lift)) / sy]
}

function callingSample(segment: CallSegment, tau: number): Sample {
  const shot = callShot(segment, tau, idleAt(tau))
  const ctx = renderContext()
  const t = warp(shot.t0)
  const f = originalCalling(ctx, PAL, t, { viewBox: VIEW, uid: "c" }, shot.pose)
  const torso: Torso = { d: svgBody(f.s), shoulderY: ctx.body.shoulderY }
  const staged = shot.phone ?? (shot.t0 < PICKED_UP ? pickUpScene(shot.t0) : undefined)
  let scene = staged ? phoneScene(torso, f, PAL, staged) : onTheCall(torso, f, t)
  const follow = t >= RELEASE ? followingThrough(torso, f, t) : undefined
  if (follow !== undefined) scene = { ...scene, arm: follow }
  if (shot.exit !== undefined)
    scene = phoneLeaving(torso, f.TF, scene.arm, scene.flying, phoneProp(PAL), shot.exit)
  const toBodySpace = invert(parseTransform(svgTransform(f.s)))
  const flying = FLYING.exec(scene.flying)?.[1]?.split(" ").map(Number)
  const held = scene.arm?.prop?.M ?? null
  const phone = held ?? (flying ? multiply(toBodySpace, flyingMatrix(flying)) : null)
  const right = scene.arm?.arm
    ? {
        arm: scene.arm.arm,
        layer: "front" as const,
        hand: holdsWithHand(scene.arm)
      }
    : null
  return { pose: shot.pose, body: torso.d, arms: { left: null, right }, phone, board: null }
}

const holdsWithHand = (p: PosedArm): number => p.over ?? 0

function holding(torso: Torso, propM: Matrix, grow = 1): PosedArm | null {
  return poseArm(torso, { side: 1, grow, grip: phoneProp(PAL), propM })
}

function onTheCall(torso: Torso, f: OriginalCalling, t: number): Scene {
  const toBody = invert(f.TF)
  const none = { arm: null, flying: "" }
  if (!(f.phoneGroup || (t >= WIND[0] && t < FLING[1] + 0.3))) return none
  if (t < WIND[0] && f.held && f.phoneM)
    return { arm: holding(torso, multiply(toBody, f.phoneM)), flying: "" }
  if (t < WIND[0]) return none
  const q = phoneFlight(f.phoneTransform ?? STILL_PHONE, f.held, t)
  const M = multiply(f.OM, placement(q))
  if (q.held) return { arm: holding(torso, multiply(toBody, M)), flying: "" }
  return { arm: null, flying: `<g transform="matrix(${M.join(" ")})"></g>` }
}

function followingThrough(
  torso: Torso,
  f: OriginalCalling,
  t: number
): PosedArm | null | undefined {
  const ctx = renderContext()
  const g = 1 - smootherstep((t - TUCK) / 0.42)
  if (!(g > 0.005)) return undefined
  const tip = tipAtRelease()
  const b = apply(invert(f.TF), followThrough(tip, ctx.body.zones?.dy ?? 0, Math.min(t, TUCK)))
  return poseArm(torso, { side: 1, grow: g, target: b })
}

function tipAtRelease(): Point {
  const cached = tipsAtRelease.get("official")
  if (cached) return cached
  const tr = RELEASE - 1e-4
  const fresh = renderContext()
  const f = originalCalling(fresh, PAL, tr, { viewBox: VIEW, uid: "rl" })
  const torso = { d: svgBody(f.s), shoulderY: fresh.body.shoulderY }
  const q = phoneFlight(f.phoneTransform ?? STILL_PHONE, f.held, tr)
  const p = holding(torso, multiply(invert(f.TF), multiply(f.OM, placement(q))))
  const tip = apply(f.TF, p?.tip ?? [0, 0])
  tipsAtRelease.set("official", tip)
  return tip
}

function flyingMatrix(values: ReadonlyArray<number>): Matrix {
  const [a = 1, b = 0, c = 0, d = 1, e = 0, g = 0] = values
  return [a, b, c, d, e, g]
}
