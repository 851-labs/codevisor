import { normalize, RAD, s01, wrapDegrees, wrapRadians, type Point } from "../geometry/math.js"
import type { ArmLayer } from "./compose.js"
import { outlinePoly, signedDistance } from "./outline-poly.js"
import { bendOf, reach } from "./reach.js"
import {
  armOrigin,
  blendArms,
  growth,
  MEDIUM_REACH,
  restArm,
  scaled,
  spineTip,
  type RigArm,
  type Torso
} from "./rig-arm.js"

export type Matrix = readonly [number, number, number, number, number, number]

export interface ArmProp {
  readonly svg: string
  readonly scale: number
  readonly grip: Point
  readonly gripDir: Point
  readonly sil: ReadonlyArray<Point>
  readonly past: number
  readonly over?: "hand"
  readonly hand?: { readonly len?: number }
  readonly holdFrom?: "back"
}

export interface ArmPoseOptions {
  readonly side: number
  readonly grow?: number
  readonly target?: Point | undefined
  readonly t?: number
  readonly grip?: ArmProp
  readonly propM?: Matrix
  readonly curl?: number
}

export interface HeldProp {
  readonly M: Matrix
  readonly svg: string
}

export interface PosedArm {
  readonly side: number
  readonly arm: RigArm | null
  readonly tip: Point
  readonly tipDir: number
  readonly layer: ArmLayer
  readonly prop?: HeldProp
  readonly over?: number
  readonly frontClip?: string
}

export const applyMatrix = (m: Matrix, [x, y]: Point): Point => [
  m[0] * x + m[2] * y + m[4],
  m[1] * x + m[3] * y + m[5]
]

export function poseArm(torso: Torso, opts: ArmPoseOptions): PosedArm | null {
  const { side, grip } = opts
  const given = grip && opts.propM ? givenGrip(grip, opts.propM, side) : null
  const w = Math.max(0, Math.min(1, opts.grow ?? 1))
  const g = growth(w)
  const bud = restArm(torso, side, opts.t || 0)
  const handLen = grip && grip.over === "hand" ? (grip.hand?.len ?? 20) * Math.max(0.4, g) : 0
  if (g < 0.02) return null

  const O0 = armOrigin(torso, side)
  const target = given ? given.G : opts.target
  const full = alignedWith(bud, target ? reachFor(torso, side, O0, target, bud, opts.curl) : bud)
  const arm = scaled({ ...blendArms(bud, full, w), R: O0 }, g)
  const { tip, dir } = spineTip(arm)
  const prop = heldProp(torso, side, tip, dir, grip, opts.propM, given !== null)
  const posed: PosedArm = { side, arm, tip, tipDir: dir, layer: "front", ...(prop ? { prop } : {}) }
  return prop && handLen ? { ...posed, over: handLen } : posed
}

function reachFor(
  torso: Torso,
  side: number,
  O0: Point,
  T: Point,
  bud: RigArm,
  curl: number | undefined
): RigArm {
  const d0 = Math.hypot(T[0] - O0[0], T[1] - O0[1])
  const u: Point =
    d0 > 0.5
      ? [(T[0] - O0[0]) / d0, (T[1] - O0[1]) / d0]
      : [Math.cos(bud.th * RAD), Math.sin(bud.th * RAD)]
  const TM: Point =
    d0 < MEDIUM_REACH ? [O0[0] + u[0] * MEDIUM_REACH, O0[1] + u[1] * MEDIUM_REACH] : T
  const m = reach(torso, side, TM, { curl, from: O0, upCurl: bendOf(torso, side, O0, TM) })
  if (d0 >= MEDIUM_REACH) return m
  return shortenedToward(m, O0, T, d0)
}

const shortened = (m: RigArm, f: number): RigArm => ({
  ...m,
  L: m.L * f,
  turn: (v) => m.turn(v * f)
})

function shortenedToward(m: RigArm, O0: Point, T: Point, d0: number): RigArm {
  let bf = d0 / MEDIUM_REACH
  let bd = 1e9
  for (let k = 1; k <= 40; k++) {
    const f = k / 40
    const e = spineTip(shortened(m, f)).tip
    const dd = Math.hypot(e[0] - T[0], e[1] - T[1])
    if (dd < bd) {
      bd = dd
      bf = f
    }
  }
  const sh = shortened(m, Math.max(0.05, bf))
  const e = spineTip(sh).tip
  const rot = wrapDegrees(
    (Math.atan2(T[1] - O0[1], T[0] - O0[0]) - Math.atan2(e[1] - O0[1], e[0] - O0[0])) / RAD
  )
  return { ...sh, th: sh.th + (d0 > 0.5 ? rot : 0) }
}

function alignedWith(bud: RigArm, full: RigArm): RigArm {
  let th = full.th
  while (th - bud.th > 180) th -= 360
  while (th - bud.th <= -180) th += 360
  return th === full.th ? full : { ...full, th }
}

function heldProp(
  torso: Torso,
  side: number,
  tip: Point,
  tipDir: number,
  grip: ArmProp | undefined,
  propM: Matrix | undefined,
  given: boolean
): HeldProp | null {
  if (given && grip && propM) return { M: propM, svg: grip.svg }
  if (!grip) return null
  const u = clearOfBody(torso, tip, gripWay(side, tipDir))
  const past = grip.past || 0
  return { M: propMatrix(grip, [tip[0] - u[0] * past, tip[1] - u[1] * past], u), svg: grip.svg }
}

function clearOfBody(torso: Torso, tip: Point, u: Point): Point {
  const sd = signedDistance(outlinePoly(torso.d), tip).d
  const wC = sd > -14 ? 1 - s01((sd - 42) / 14) : 1 - s01((-sd - 14) / 22)
  if (!(wC > 0)) return u
  const a0 = Math.atan2(u[1], u[0])
  const a1 = Math.atan2(u[1], -u[0])
  const da = wrapRadians(a1 - a0)
  const a = a0 + overTheTop(a0, da) * wC
  return [Math.cos(a), Math.sin(a)]
}

function overTheTop(a0: number, da: number): number {
  if (Math.sin(a0 + da / 2) < 0) return da
  return da > 0 ? da - 2 * Math.PI : da + 2 * Math.PI
}

export function gripWay(side: number, dir: number): Point {
  const d: Point = [Math.cos(dir * RAD), Math.sin(dir * RAD)]
  return normalize([-side * (Math.abs(d[0]) + 0.8), 0.1 * d[1]])
}

export function propMatrix(prop: ArmProp, tip: Point, u: Point): Matrix {
  const s = prop.scale || 1
  const r = Math.atan2(u[1], u[0]) - Math.atan2(prop.gripDir[1], prop.gripDir[0])
  const c = Math.cos(r) * s
  const sn = Math.sin(r) * s
  const G: Point = [tip[0] + u[0] * (prop.past || 0), tip[1] + u[1] * (prop.past || 0)]
  const [gx, gy] = prop.grip
  return [c, sn, -sn, c, G[0] - (c * gx - sn * gy), G[1] - (sn * gx + c * gy)]
}

function givenGrip(prop: ArmProp, M: Matrix, side: number): { G: Point; u: Point; tip: Point } {
  const G = applyMatrix(M, prop.grip)
  const a0: Point = [
    M[0] * prop.gripDir[0] + M[2] * prop.gripDir[1],
    M[1] * prop.gripDir[0] + M[3] * prop.gripDir[1]
  ]
  const a = normalize(a0)
  const u: Point = prop.holdFrom === "back" || a[0] * side + a[1] * 0.35 < 0 ? a : [-a[0], -a[1]]
  const past = prop.past || 0
  return { G, u, tip: [G[0] - u[0] * past, G[1] - u[1] * past] }
}
