import type { Body } from "../body/zones.js"
import { normalize, RAD, type Point } from "../geometry/math.js"

export interface FlipperShape {
  readonly hT: (s: number) => number
  readonly hB: (s: number) => number
  readonly cap: readonly [number, number]
  readonly filletT?: number | undefined
}

export interface CurvedOptions {
  readonly p?: number
  readonly h0?: number
  readonly tip?: number
  readonly topTip?: number
  readonly topRound?: number
  readonly topP?: number
  readonly filletT?: number
  readonly cap?: readonly [number, number]
}

export interface SpinePoint {
  readonly p: Point
  readonly dir: Point
}

export interface Spine {
  readonly L: number
  readonly at: (s: number) => SpinePoint
}

export const FLIPPER_LENGTH = 28.1
export const FLIPPER_REST = 19.8
export const TOP_START = 4
export const UNDER_START = 10.9

export const flipperTop = (s: number): number => 13.7 - 0.19 * (s - 4)

export const flipperUnder = (s: number): number =>
  5 + 11.6 * Math.max(0, (FLIPPER_LENGTH - s) / 17.2) ** 1.15

export const curvedFlipper = ({
  p = 2.2,
  h0 = 16.6,
  tip = 4,
  topTip = 9.1,
  topRound = 2,
  topP,
  filletT,
  cap = [6, 4.5]
}: CurvedOptions = {}): FlipperShape => ({
  hT: (s) => {
    const v = Math.max(0, Math.min(1, (s - TOP_START) / (FLIPPER_LENGTH - TOP_START)))
    if (topP) return topTip + (13.7 - topTip) * (1 - v ** topP) - topRound * v ** 3
    return 13.7 + (topTip - 13.7) * v - topRound * v ** 3
  },
  filletT,
  hB: (s) => {
    const v = Math.max(0, Math.min(1, (s - UNDER_START) / (FLIPPER_LENGTH - UNDER_START)))
    return tip + (h0 - tip) * (1 - v ** p)
  },
  cap
})

export const BOT_MASCOT_ARM = {
  rest: 14,
  shaft: 34.61,
  shape: { p: 1.7, h0: 16.6, tip: 4.5, topRound: 1.5, topP: 1.9, filletT: 28 }
} as const

export const rotateVector = ([x, y]: Point, a: number): Point => {
  const c = Math.cos(a)
  const s = Math.sin(a)
  return [x * c - y * s, x * s + y * c]
}

export const dirBetween = (a: Point, b: Point): Point => normalize([b[0] - a[0], b[1] - a[1]])

export const addScaled = (p: Point, v: Point, k = 1): Point => [p[0] + v[0] * k, p[1] + v[1] * k]

export function arcSpine(
  R: Point,
  theta: number,
  shaft: number,
  rho: number,
  phi: number,
  sigma: number
): Spine {
  const d: Point = [Math.cos(theta * RAD), Math.sin(theta * RAD)]
  const E = addScaled(R, d, shaft)
  const Ctr = addScaled(E, rotateVector(d, (sigma * Math.PI) / 2), rho)
  const L = shaft + rho * phi * RAD
  return {
    L,
    at: (s) => {
      if (s <= shaft || !phi) return { p: addScaled(R, d, s), dir: d }
      const a = (sigma * (s - shaft)) / rho
      return {
        p: addScaled(Ctr, rotateVector([E[0] - Ctr[0], E[1] - Ctr[1]], a)),
        dir: rotateVector(d, a)
      }
    }
  }
}

export function curveSpine(R: Point, [c1, c2, e]: readonly [Point, Point, Point]): Spine {
  const P = [R, c1, c2, e] as const
  const at0 = (u: number): Point => {
    const k = (i: 0 | 1): number =>
      (1 - u) ** 3 * P[0][i] +
      3 * u * (1 - u) ** 2 * P[1][i] +
      3 * u * u * (1 - u) * P[2][i] +
      u ** 3 * P[3][i]
    return [k(0), k(1)]
  }
  const N = 160
  const pts: Array<Point> = []
  const len = [0]
  for (let i = 0; i <= N; i++) {
    pts.push(at0(i / N))
    if (i)
      len.push(len[i - 1]! + Math.hypot(pts[i]![0] - pts[i - 1]![0], pts[i]![1] - pts[i - 1]![1]))
  }
  const L = len[N]!
  return {
    L,
    at: (s) => {
      if (s <= 0) {
        const d = dirBetween(pts[0]!, pts[1]!)
        return { p: addScaled(pts[0]!, d, s), dir: d }
      }
      if (s >= L) {
        const d = dirBetween(pts[N - 1]!, pts[N]!)
        return { p: addScaled(pts[N]!, d, s - L), dir: d }
      }
      let i = 1
      while (len[i]! < s) i++
      const a = pts[i - 1]!
      const b = pts[i]!
      const u = (s - len[i - 1]!) / (len[i]! - len[i - 1]! || 1)
      return { p: [a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u], dir: dirBetween(a, b) }
    }
  }
}

export interface SpinePath {
  readonly L: number
  readonly turn: (u: number) => number
}

export function pathSpine(R: Point, theta: number, { L, turn }: SpinePath): Spine {
  const N = 240
  const pts: Array<Point> = [R]
  for (let i = 0; i < N; i++) {
    const a = (theta + turn((i + 0.5) / N)) * RAD
    const p = pts[i]!
    pts.push([p[0] + (Math.cos(a) * L) / N, p[1] + (Math.sin(a) * L) / N])
  }
  const dirAt = (u: number): Point => {
    const a = (theta + turn(Math.max(0, Math.min(1, u)))) * RAD
    return [Math.cos(a), Math.sin(a)]
  }
  return {
    L,
    at: (s) => {
      if (s <= 0) return { p: addScaled(R, dirAt(0), s), dir: dirAt(0) }
      if (s >= L) return { p: addScaled(pts[N]!, dirAt(1), s - L), dir: dirAt(1) }
      const f = (s / L) * N
      const i = Math.floor(f)
      const u = f - i
      const a = pts[i]!
      const b = pts[i + 1]!
      return { p: [a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u], dir: dirAt(s / L) }
    }
  }
}

export function aimCurl(
  R: Point,
  C: Point,
  rho: number,
  sigma: number
): { theta: number; shaft: number } {
  const v: Point = [C[0] - R[0], C[1] - R[1]]
  const m = Math.hypot(...v)
  const shaft = Math.sqrt(Math.max(1, m * m - rho * rho))
  return { theta: Math.atan2(v[1], v[0]) / RAD - (sigma * Math.atan2(rho, shaft)) / RAD, shaft }
}

let polyCache: { body: string; poly: ReadonlyArray<Point> } | null = null

export function edgeX(body: string, y: number, side: number): number {
  const P = outlineVertices(body)
  let best = side > 0 ? -Infinity : Infinity
  for (let i = 0; i < P.length; i++) {
    const a = P[i]!
    const b = P[(i + 1) % P.length]!
    if ((a[1] - y) * (b[1] - y) > 0 || a[1] === b[1]) continue
    const x = a[0] + ((b[0] - a[0]) * (y - a[1])) / (b[1] - a[1])
    best = side > 0 ? Math.max(best, x) : Math.min(best, x)
  }
  return best
}

export interface FlipperArm {
  readonly side: number
  readonly y: number
  readonly theta: number
  readonly shaft: number
  readonly rho?: number
  readonly phi?: number
  readonly sigma?: number
  readonly rootIn?: number
  readonly path?: SpinePath
  readonly curve?: readonly [Point, Point, Point]
  readonly bend?: (s: number, L: number) => number
  readonly even?: boolean
  readonly rigid?: boolean
  readonly front?: boolean
  readonly softRoot?: boolean
  readonly noShade?: boolean
  readonly shape?: FlipperShape
  readonly thick?: number
  readonly filletB?: number
}

export function restingArm(
  body: Body,
  side: number,
  overrides: Partial<FlipperArm> = {}
): FlipperArm {
  return {
    side,
    y: body.shoulderY,
    theta: side > 0 ? BOT_MASCOT_ARM.rest : 180 - BOT_MASCOT_ARM.rest,
    shaft: BOT_MASCOT_ARM.shaft,
    even: true,
    rigid: true,
    shape: curvedFlipper(BOT_MASCOT_ARM.shape),
    noShade: side > 0,
    ...overrides
  }
}

function outlineVertices(body: string): ReadonlyArray<Point> {
  if (polyCache?.body === body) return polyCache.poly
  const n = (body.match(/-?\d+(\.\d+)?/g) ?? []).map(Number)
  const poly: Array<Point> = []
  for (let i = 0; i + 1 < n.length; i += 2) poly.push([n[i]!, n[i + 1]!])
  polyCache = { body, poly }
  return poly
}
