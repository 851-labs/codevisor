import { clamp, normalize, RAD, s01, subtract, type Point } from "../geometry/math.js"
import type { EdgeSample } from "./arm-edges.js"
import { signedDistance, type Poly } from "./outline-poly.js"
import { ARM_LENGTH, spineTip, type RigArm } from "./rig-arm.js"

export interface Mouth {
  readonly poly: Poly
  readonly R: Point
  readonly S: Point
  readonly nS: Point
  readonly tS: Point
  readonly W: number
  readonly Sb: number
  readonly k: number
  readonly sw: number
  readonly hw: number
  readonly armL: number
  readonly preferred: number
}

export interface MouthEdge {
  readonly list: ReadonlyArray<EdgeSample>
  readonly dep: Point
  readonly into: boolean
}

export const dot = (a: Point, b: Point): number => a[0] * b[0] + a[1] * b[1]

export function mouthOf(
  poly: Poly,
  arm: RigArm,
  topList: ReadonlyArray<EdgeSample>,
  bottomList: ReadonlyArray<EdgeSample>
): Mouth {
  const sc = arm.scale ?? 1
  const k = clamp(sc, 0.3, 1)
  const R = arm.R
  const sw = 16 * clamp(sc / 0.5, 0.06, 1)
  const rS = signedDistance(poly, signedDistance(poly, R).q)
  const S = rS.q
  const nS = rS.n
  const tS: Point = [-nS[1], nS[0]]
  const cross = subtract(topList[0]!.p, bottomList[0]!.p)
  const W = Math.hypot(...cross) || 1
  const along = (cross[0] * tS[0] + cross[1] * tS[1]) / W
  const ov = (cross[0] * nS[0] + cross[1] * nS[1]) / W
  const short = spineTip({ ...arm, L: Math.max(1, 0.8 * ARM_LENGTH * k) })
  const dR = normalize(subtract(short.tip, arm.R))
  const aT = dR[0] * tS[0] + dR[1] * tS[1]
  const d0: Point = [
    Math.cos((arm.th + arm.turn(0.1)) * RAD),
    Math.sin((arm.th + arm.turn(0.1)) * RAD)
  ]
  const wTrail = 1 - s01((-d0[1] - 0.2) / 0.3)
  return {
    poly,
    R,
    S,
    nS,
    tS,
    W,
    Sb: Math.min(1.3 * ARM_LENGTH * k, 0.7 * arm.L),
    k,
    sw,
    hw: sw / 2,
    armL: arm.L,
    preferred: along - 2 * ov * aT * wTrail >= 0 ? 1 : -1
  }
}

export function mouthEnd(m: Mouth, sg: number, sign: number): Point {
  const p: Point = [
    m.S[0] + sign * ((m.tS[0] * sg * m.W) / 2),
    m.S[1] + sign * ((m.tS[1] * sg * m.W) / 2)
  ]
  return signedDistance(m.poly, p).q
}

export function fromMouth(m: Mouth, list: ReadonlyArray<EdgeSample>, end: Point): MouthEdge {
  const dirAt = (k: number): Point =>
    normalize(subtract(list[Math.min(list.length - 1, k + 1)]!.p, list[Math.max(0, k - 1)]!.p))
  const j = joinIndex(m, list, end, dirAt)
  const Q = list[j]!.p
  const dQ = dirAt(j)
  const dep = normalize(normalize(subtract(Q, end)))
  const Lc = Math.hypot(...subtract(Q, end))
  const P1: Point = [end[0] + (dep[0] * Lc) / 3, end[1] + (dep[1] * Lc) / 3]
  const P2: Point = [Q[0] - (dQ[0] * Lc) / 3, Q[1] - (dQ[1] * Lc) / 3]
  const n = Math.max(2, Math.ceil(Lc))
  const sj = list[j]!.s
  const head = Array.from({ length: n }, (_, i): EdgeSample => {
    const u = i / n
    const v = 1 - u
    const at = (c: 0 | 1): number =>
      v ** 3 * end[c] + 3 * v * v * u * P1[c] + 3 * v * u * u * P2[c] + u ** 3 * Q[c]
    return { s: (sj * i) / n, p: [at(0), at(1)] }
  })
  return { list: [...head, ...list.slice(j)], dep, into: -dot(dep, m.nS) > 0.15 }
}

function joinIndex(
  m: Mouth,
  list: ReadonlyArray<EdgeSample>,
  end: Point,
  dirAt: (k: number) => Point
): number {
  let j = list.findIndex((q) => q.s >= m.Sb)
  if (j < 1) j = Math.min(1, list.length - 1)
  const agreement = dot(normalize(subtract(list[j]!.p, end)), dirAt(j))
  if (!(agreement < 0.5)) return j
  let bj = j
  let bv = -2
  for (let k = j; k < list.length - 2 && list[k]!.s < 0.75 * m.armL; k++) {
    const v = dot(normalize(subtract(list[k]!.p, end)), dirAt(k))
    if (v > bv) {
      bv = v
      bj = k
    }
    if (v > 0.5) break
  }
  return bj
}
