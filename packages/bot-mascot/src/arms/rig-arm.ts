import { lerp, lerp2, RAD, smootherstep, type Point } from "../geometry/math.js"
import { idleAt } from "../moods/moods.js"
import { BOT_MASCOT_ARM, curvedFlipper, edgeX, FLIPPER_LENGTH } from "./flipper.js"

export interface ArmSleeve {
  readonly c: string
  readonly len: number
  readonly cuff: string
  readonly op: number
}

export interface RigArm {
  readonly R: Point
  readonly th: number
  readonly L: number
  readonly turn: (u: number) => number
  readonly scale?: number
  readonly c?: number
  readonly sleeve?: ArmSleeve
  readonly fullLength?: number
  readonly pivot?: Point
}

export interface Torso {
  readonly d: string
  readonly shoulderY: number
}

export interface SpineTip {
  readonly tip: Point
  readonly dir: number
}

export const ARM_LENGTH = BOT_MASCOT_ARM.shaft
export const MEDIUM_REACH = 2.7 * ARM_LENGTH
export const ARM_TOP = 13.7
export const FLIPPER = curvedFlipper(BOT_MASCOT_ARM.shape)
export const LS = FLIPPER_LENGTH

const curveOf = (k: (u: number) => number): ((u: number) => number) => {
  const N = 400
  const c = [0]
  for (let i = 0; i < N; i++) c.push(c[i]! + k((i + 0.5) / N) / N)
  const T = c[N]!
  return (u) => {
    const f = Math.max(0, Math.min(1, u)) * N
    const i = Math.min(N - 1, Math.floor(f))
    return (c[i]! + (c[i + 1]! - c[i]!) * (f - i)) / T
  }
}

export const RIG_CURVE = curveOf((u) => u ** 1.2)

export const shoulder = (torso: Torso, side: number): Point => [
  edgeX(torso.d, torso.shoulderY, side),
  torso.shoulderY
]

export function armStart(
  torso: Torso,
  side: number
): { th: number; y: number; rootIn: number; R: Point } {
  const y0 = torso.shoulderY
  const e0 = edgeX(torso.d, y0 - 3, side)
  const e1 = edgeX(torso.d, y0 + 3, side)
  const th = Math.atan2(6, e1 - e0) / RAD
  const d: Point = [Math.cos(th * RAD), Math.sin(th * RAD)]
  const n: Point = side > 0 ? [d[1], -d[0]] : [-d[1], d[0]]
  const R: Point = [edgeX(torso.d, y0, side) - n[0] * ARM_TOP, y0 - n[1] * ARM_TOP]
  const y = R[1]
  return { th, y, rootIn: side * (edgeX(torso.d, y, side) - R[0]), R }
}

export const armOrigin = (torso: Torso, side: number): Point => armStart(torso, side).R

const breath = (x: number): number => ((idleAt(x).sy ?? 1) - 1) / 0.012

export function restArm(torso: Torso, side: number, t: number): RigArm {
  const lag = breath(t - 0.25)
  const bend = 5 * (breath(t - 0.25) - breath(t - 0.05))
  const th = side > 0 ? BOT_MASCOT_ARM.rest - 4 * lag : 180 - BOT_MASCOT_ARM.rest + 4 * lag
  return { R: armOrigin(torso, side), th, L: ARM_LENGTH, turn: (u) => side * bend * u }
}

export const blendArms = (a: RigArm, b: RigArm, w: number): RigArm => ({
  R: lerp2(a.R, b.R, w),
  th: lerp(a.th, b.th, w),
  L: lerp(a.L, b.L, w),
  turn: (u) => lerp(a.turn(u), b.turn(u), w)
})

export const growth = (w: number): number => smootherstep(Math.min(1, w * 1.6))

export function growFor(g: number): number {
  let lo = 0
  let hi = 1 / 1.6
  for (let i = 0; i < 40; i++) {
    const mid = (lo + hi) / 2
    if (growth(mid) < g) lo = mid
    else hi = mid
  }
  return (lo + hi) / 2
}

export function grownBy(arm: RigArm): number {
  if (arm.fullLength === undefined) return 1
  return clamp01(arm.L / (arm.fullLength || 1))
}

const clamp01 = (v: number): number => Math.max(0, Math.min(1, v))

export const EMERGE_BACK = 22

export function emerging(arm: RigArm, g: number): RigArm {
  if (!(g < 1)) return arm
  const a = (arm.th + arm.turn(0)) * RAD
  const back = EMERGE_BACK * (1 - g)
  const R: Point = [arm.R[0] - Math.cos(a) * back, arm.R[1] - Math.sin(a) * back]
  const L = Math.max(0.5, arm.L * g)
  return { ...arm, R, L, turn: (u) => arm.turn(u * g), fullLength: arm.L, pivot: arm.R }
}

export const rootRadius = (arm: RigArm): number =>
  0.8 * ARM_LENGTH * Math.max(0.3, Math.min(1, arm.scale ?? 1))

export function spinePoints(arm: RigArm, N = 24): ReadonlyArray<Point> {
  const out: Array<Point> = []
  let x = arm.R[0]
  let y = arm.R[1]
  for (let i = 0; i < N; i++) {
    const a = (arm.th + arm.turn((i + 0.5) / N)) * RAD
    x += (Math.cos(a) * arm.L) / N
    y += (Math.sin(a) * arm.L) / N
    out.push([x, y])
  }
  return out
}

export function spineTip(arm: RigArm): SpineTip {
  const N = 160
  let x = arm.R[0]
  let y = arm.R[1]
  for (let i = 0; i < N; i++) {
    const a = (arm.th + arm.turn((i + 0.5) / N)) * RAD
    x += (Math.cos(a) * arm.L) / N
    y += (Math.sin(a) * arm.L) / N
  }
  return { tip: [x, y], dir: arm.th + arm.turn(1) }
}
