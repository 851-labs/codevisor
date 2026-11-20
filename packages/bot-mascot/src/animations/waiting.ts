import { armEdges, type EdgeSample } from "../arms/arm-edges.js"
import { poseArm, type Matrix, type PosedArm } from "../arms/arm-pose.js"
import { SMALLEST_HAND } from "../arms/prop-hand.js"
import type { RigArm, Torso } from "../arms/rig-arm.js"
import { drawRig } from "../arms/rig-draw.js"
import { palette, type Palette } from "../color/palette.js"
import { handsetColor } from "../effects/handset.js"
import { lightIn, strapSvg, WATCH_STEEL, watchFaceSvg, WRISTWATCH } from "../effects/watch.js"
import {
  distance,
  f2,
  lerp,
  lerp2,
  normalize,
  RAD,
  s01,
  smootherstep,
  type Point
} from "../geometry/math.js"
import { IDLE_LOOP } from "../moods/expressions.js"
import { blinkAt } from "../moods/timing.js"
import type { BotMascotPose, FacePose } from "../pose.js"
import type { RenderContext } from "../render/context.js"
import { renderFrame } from "../render/frame.js"
import { svgBody, withSize } from "../render/svg-parts.js"
import { boardPop } from "./idle-working.js"

export interface WatchCheck {
  readonly steady: number
  readonly look: number
  readonly lean: number
  readonly grow: number
  readonly raised: number
  readonly closer: number
}

export interface WatchOnWrist {
  readonly pop: number
  readonly at: Point
  readonly face: Point
  readonly turn: number
  readonly halves: ReadonlyArray<StrapHalf>
}

export interface StrapHalf {
  readonly corners: ReadonlyArray<Point>
  readonly shaded: boolean
}

export interface WaitingArm {
  readonly arm: PosedArm | null
  readonly watch: WatchOnWrist | null
}

export interface WaitingShot {
  readonly t: number
  readonly clock: number
  readonly pose: BotMascotPose
  readonly viewBox: string
  readonly uid: string
  readonly size?: number
}

type Span = readonly [number, number]

interface Glance {
  readonly turn: number
  readonly up: number
}

interface Stance {
  readonly lean: number
  readonly squash: number
}

interface Look {
  readonly lookTo: Span
  readonly lookAway: Span
  readonly down: Span
  readonly up: Span
  readonly closer: Span
  readonly ease: Span
  readonly depth: number
}

interface Wrist {
  readonly at: Point
  readonly face: Point
  readonly up: Point
  readonly halves: readonly [ReadonlyArray<Point>, ReadonlyArray<Point>]
}

export const WAITING_LOOP = IDLE_LOOP
export const WATCH_FACING = 0.62

const SIDE = 1
const OVERSHOOT = 1.4
const READING_WIDE = 0.1
const FOOT_REACH = 80
const HEAD_TILT = -2
const GROUND: Point = [250, 412]
const HEAD: Point = [250, 236]
const WRIST = { back: 24, over: 4.5, proud: 9, clearFrom: 15, clearOver: 13 } as const
const NEVER: Span = [100, 101]

const BEATS = {
  steady: [4.4, 4.7],
  release: [9.3, 9.6],
  armOut: [4.7, 5.3],
  raise: [5.05, 5.65],
  lower: [8.45, 8.9],
  armIn: [8.75, 9.3]
} as const satisfies Record<string, Span>
export const WATCH_CHECK_FROM = BEATS.steady[0]
const BLINKS = [4.67, 6.02, 6.72] as const

const LOOKS: ReadonlyArray<Look> = [
  {
    lookTo: [4.6, 4.8],
    lookAway: [5.95, 6.15],
    down: [5.1, 5.55],
    up: [5.95, 6.4],
    closer: NEVER,
    ease: NEVER,
    depth: 0.7
  },
  {
    lookTo: [6.75, 6.92],
    lookAway: [8.35, 8.55],
    down: [6.8, 7.3],
    up: [8.35, 8.9],
    closer: [7.5, 7.8],
    ease: [8.05, 8.3],
    depth: 1
  }
]

const ARM = { out: [272, 322], held: [236, 332], closer: [236, 328] } as const
const EYE = {
  out: { turn: 0.55, up: 1.4 },
  held: { turn: 0.12, up: 3 },
  closer: { turn: 0.12, up: 3.3 }
} as const satisfies Record<string, Glance>
const HELD: Stance = { lean: 1.5, squash: 0.08 }
const CLOSER: Stance = { lean: 0.5, squash: 0.03 }

export function watchCheck(t: number): WatchCheck {
  const out = smootherstep(within(t, BEATS.armOut))
  const back = smootherstep(within(t, BEATS.armIn))
  return {
    steady: s01(within(t, BEATS.steady)) * (1 - s01(within(t, BEATS.release))),
    look: sum(LOOKS, (l) => s01(within(t, l.lookTo)) * (1 - s01(within(t, l.lookAway)))),
    lean: sum(
      LOOKS,
      (l) => l.depth * smootherstep(within(t, l.down)) * (1 - smootherstep(within(t, l.up)))
    ),
    grow: out * (1 - back),
    raised: flickedUp(within(t, BEATS.raise)) * (1 - smootherstep(within(t, BEATS.lower))),
    closer: sum(LOOKS, (l) => s01(within(t, l.closer)) * (1 - s01(within(t, l.ease))))
  }
}

export function waitingPose(t: number, idle: BotMascotPose): BotMascotPose {
  const check = watchCheck(t)
  if (check.steady <= 0) return idle

  const stance = stanceAt(check)
  return {
    ...idle,
    sy: (idle.sy ?? 1) - stance.squash,
    lean: (idle.lean ?? 0) + stance.lean,
    y: (idle.y ?? 0) + FOOT_REACH * Math.sin(Math.abs(stance.lean) * RAD),
    tilt: lerp(idle.tilt ?? 0, HEAD_TILT, check.steady),
    twist: lerp(idle.twist ?? 0, 0, check.steady),
    face: watching(idle.face ?? {}, check, t)
  }
}

export function renderWaiting(ctx: RenderContext, color: string, shot: WaitingShot): string {
  const svg = renderFrame(ctx, color, shot.pose, { viewBox: shot.viewBox, uid: shot.uid })
  const torso = { d: svgBody(svg), shoulderY: ctx.body.shoulderY }
  const arm = wristwatchArm(torso, shot, palette(color))
  if (!arm) return withSize(svg, shot.size)

  const rig = { uid: `${shot.uid}a`, pal: color, pose: shot.pose }
  return withSize(drawRig(ctx, svg, [arm], rig), shot.size)
}

const within = (t: number, [from, to]: Span): number =>
  Math.max(0, Math.min(1, (t - from) / (to - from)))

const flickedUp = (u: number): number =>
  1 + (OVERSHOOT + 1) * (u - 1) ** 3 + OVERSHOOT * (u - 1) ** 2

const sum = <T>(list: ReadonlyArray<T>, of: (item: T) => number): number =>
  list.reduce((total, item) => total + of(item), 0)

function stanceAt(check: WatchCheck): Stance {
  const mixed = (key: keyof Stance): number => HELD[key] * check.lean + CLOSER[key] * check.closer
  return { lean: mixed("lean"), squash: mixed("squash") }
}

function watching(face: FacePose, check: WatchCheck, t: number): FacePose {
  const at = watchGlance(check)
  return {
    ...face,
    turn: lerp(face.turn ?? 0, at.turn, check.look),
    up: lerp(face.up ?? 0, at.up, check.look),
    blink: Math.min(lerp(face.blink ?? 1, 1, check.look), blinkAt(t, ...BLINKS)),
    wide: (face.wide ?? 1) + READING_WIDE * check.closer
  }
}

function watchGlance(check: WatchCheck): Glance {
  const raised = Math.min(1, check.raised)
  return {
    turn: lerp(lerp(EYE.out.turn, EYE.held.turn, raised), EYE.closer.turn, check.closer),
    up: lerp(lerp(EYE.out.up, EYE.held.up, raised), EYE.closer.up, check.closer)
  }
}

export function waitingArm(
  torso: Torso,
  t: number,
  clock: number,
  pose: BotMascotPose
): WaitingArm {
  const check = watchCheck(t)
  const reach = lerp2(lerp2(ARM.out, ARM.held, check.raised), ARM.closer, check.closer)
  const target = inHisBody(reach, pose)
  const posed = poseArm(torso, { side: SIDE, grow: check.grow, target, t: clock })
  if (!posed?.arm) return { arm: posed, watch: null }

  const wrist = wristOf(posed.arm)
  const pop = Math.min(boardPop(check.grow), clearOfHisSide(posed.arm, wrist))
  if (pop <= SMALLEST_HAND) return { arm: posed, watch: null }

  return { arm: posed, watch: watchOn(wrist, pop) }
}

function wristwatchArm(torso: Torso, shot: WaitingShot, P: Palette): PosedArm | null {
  const { arm, watch } = waitingArm(torso, shot.t, shot.clock, shot.pose)
  if (!arm || !watch) return arm

  const prop = { M: scaledAbout(watch.at, watch.pop), svg: wristwatchSvg(watch, P, shot.clock) }
  return { ...arm, prop }
}

function watchOn(wrist: Wrist, pop: number): WatchOnWrist {
  return {
    pop,
    at: wrist.at,
    face: wrist.face,
    turn: Math.atan2(wrist.up[0], -wrist.up[1]),
    halves: wrist.halves.map((corners) => ({ corners, shaded: facesAway(wrist.at, corners) }))
  }
}

function inHisBody(onStage: Point, pose: BotMascotPose): Point {
  const sy = pose.sy ?? 1
  const turned = -(pose.lean ?? 0) * RAD
  const x = onStage[0] - GROUND[0]
  const y = onStage[1] - (GROUND[1] - (pose.y ?? 0))
  return [
    GROUND[0] + (x * Math.cos(turned) - y * Math.sin(turned)) / (2 - sy),
    GROUND[1] + (x * Math.sin(turned) + y * Math.cos(turned)) / sy
  ]
}

function wristOf(arm: RigArm): Wrist {
  const { ts, bs, L } = armEdges(arm, SIDE)
  const s = Math.max(0, L - WRIST.back)
  const half = WRISTWATCH.strap / 2
  const top = edgeAt(ts, s)
  const bottom = edgeAt(bs, s)
  const at: Point = lerp2(top, bottom, 0.5)
  const across = normalize([top[0] - bottom[0], top[1] - bottom[1]])
  const out = (p: Point, way: number): Point => [
    p[0] + across[0] * WRIST.over * way,
    p[1] + across[1] * WRIST.over * way
  ]
  const mid = (way: number): Point =>
    lerp2(edgeAt(ts, s + way * half), edgeAt(bs, s + way * half), 0.5)
  const up = towardHisEye(at, across)
  return {
    at,
    face: [at[0] + up[0] * WRIST.proud, at[1] + up[1] * WRIST.proud],
    up,
    halves: [
      [mid(-1), out(edgeAt(ts, s - half), 1), out(edgeAt(ts, s + half), 1), mid(1)],
      [mid(-1), out(edgeAt(bs, s - half), -1), out(edgeAt(bs, s + half), -1), mid(1)]
    ]
  }
}

function towardHisEye(at: Point, across: Point): Point {
  const facesHim = across[0] * (HEAD[0] - at[0]) + across[1] * (HEAD[1] - at[1]) >= 0
  return facesHim ? across : [-across[0], -across[1]]
}

function edgeAt(samples: ReadonlyArray<EdgeSample>, s: number): Point {
  const next = samples.findIndex((sample) => sample.s >= s)
  if (next <= 0) return samples[Math.max(0, next)]!.p
  const a = samples[next - 1]!
  const b = samples[next]!
  return lerp2(a.p, b.p, (s - a.s) / (b.s - a.s || 1))
}

const clearOfHisSide = (arm: RigArm, wrist: Wrist): number =>
  s01((distance(wrist.at, arm.pivot ?? arm.R) - WRIST.clearFrom) / WRIST.clearOver)

function wristwatchSvg(watch: WatchOnWrist, P: Palette, clock: number): string {
  const face = watchFaceSvg({
    radius: WRISTWATCH.radius,
    rim: WRISTWATCH.rim,
    metal: WATCH_STEEL,
    outline: P.outline,
    turn: watch.turn,
    facing: WATCH_FACING,
    seconds: clock
  })
  const strap = watch.halves
    .map((half) => strapSvg(half.corners, handsetColor(P.key), P.outline, half.shaded))
    .join("")
  return `${strap}<g transform="translate(${f2(watch.face[0])} ${f2(watch.face[1])}) rotate(${f2(watch.turn / RAD)})">${face}</g>`
}

function facesAway(centre: Point, corners: ReadonlyArray<Point>): boolean {
  const outer = lerp2(corners[1]!, corners[2]!, 0.5)
  const toLight = lightIn(0)
  return (outer[0] - centre[0]) * toLight[0] + (outer[1] - centre[1]) * toLight[1] < 0
}

const scaledAbout = ([x, y]: Point, k: number): Matrix => [k, 0, 0, k, x - k * x, y - k * y]
