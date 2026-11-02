import { f2, normalize, type Point } from "../geometry/math.js"
import {
  addScaled,
  arcSpine,
  curveSpine,
  dirBetween,
  edgeX,
  FLIPPER_LENGTH,
  flipperTop,
  flipperUnder,
  pathSpine,
  rotateVector,
  TOP_START,
  UNDER_START,
  type FlipperArm,
  type Spine
} from "./flipper.js"

export interface FlipperOutline {
  readonly edge: string
  readonly fill: string
  readonly joins: readonly [Point, Point]
}

const line = (P: ReadonlyArray<Point>): string => P.map(([x, y]) => `L${f2(x)} ${f2(y)}`).join("")

const PROFILE_ROOT = 12
const PROFILE_TIP = 12

export function flipperOutline(body: string, a: FlipperArm): FlipperOutline {
  const sd = a.side
  const R: Point = [edgeX(body, a.y, sd) - sd * (a.rootIn || 0), a.y]
  const sp = bentSpine(baseSpine(R, a), a)
  const topN = (dir: Point): Point => rotateVector(dir, (-sd * Math.PI) / 2)
  const { T, B } = flipperEdges(a, sp, topN)
  const cap = tipCap(a, sp, T, B)
  const ex = (y: number): number => edgeX(body, y, sd)
  const n0 = topN(sp.at(0).dir)
  const up = n0[1] <= 0 ? -1 : 1
  const joiner = new EdgeJoin(a, ex)
  const JT = a.front ? T : joiner.join(T, up, a.shape?.filletT || 14)
  const JB = a.front ? B : joiner.join(B.toReversed(), -up, a.filletB || 6).toReversed()
  const jt = JT[0]!
  const jb = JB[JB.length - 1]!
  const edge = `M${f2(jt[0])} ${f2(jt[1])}${line(JT.slice(1))}${cap}${line(JB.slice(1))}`
  const inside = -sd * 12
  const fill = a.front
    ? `${edge}Z`
    : `${edge}L${f2(jb[0] + inside)} ${f2(jb[1])}L${f2(jt[0] + inside)} ${f2(jt[1])}Z`
  return { edge, fill, joins: [jt, jb] }
}

function baseSpine(R: Point, a: FlipperArm): Spine {
  if (a.path) return pathSpine(R, a.theta, a.path)
  if (a.curve) return curveSpine(R, a.curve)
  return arcSpine(R, a.theta, a.shaft, a.rho || 20, a.phi || 0, a.sigma || 1)
}

function bentSpine(sp0: Spine, a: FlipperArm): Spine {
  const bend = a.bend
  if (!bend) return sp0
  const L = sp0.L
  return {
    L,
    at: (s) => {
      const q = sp0.at(s)
      const n = rotateVector(q.dir, (-a.side * Math.PI) / 2)
      const o = bend(s, L)
      const dO = bend(s + 0.5, L) - bend(s - 0.5, L)
      return { p: addScaled(q.p, n, o), dir: normalize(addScaled(q.dir, n, dO)) }
    }
  }
}

function profileAt(s: number, L: number): number {
  if (s <= PROFILE_ROOT) return s
  if (s >= L - PROFILE_TIP) return FLIPPER_LENGTH - (L - s)
  return (
    PROFILE_ROOT +
    ((s - PROFILE_ROOT) * (FLIPPER_LENGTH - PROFILE_TIP - PROFILE_ROOT)) /
      (L - PROFILE_TIP - PROFILE_ROOT)
  )
}

function flipperEdges(
  a: FlipperArm,
  sp: Spine,
  topN: (dir: Point) => Point
): { T: ReadonlyArray<Point>; B: ReadonlyArray<Point> } {
  const L = sp.L
  const pf = a.even
    ? (s: number): number => (s * FLIPPER_LENGTH) / L
    : (s: number): number => profileAt(s, L)
  const s0T = startOf(a, TOP_START, L)
  const s0B = startOf(a, UNDER_START, L)
  const TK = a.thick || 1
  const HT0 = a.shape?.hT || flipperTop
  const HB0 = a.shape?.hB || flipperUnder
  const top = (s: number): Point => {
    const q = sp.at(s)
    return addScaled(q.p, topN(q.dir), TK * HT0(pf(s)))
  }
  const bot = (s: number): Point => {
    const q = sp.at(s)
    return addScaled(q.p, topN(q.dir), -(TK * HB0(pf(s))))
  }
  const N = Math.max(16, Math.round(L / 1.5))
  const pts = (f: (s: number) => Point, s0: number, s1: number): Array<Point> =>
    Array.from({ length: N + 1 }, (_, i) => f(s0 + ((s1 - s0) * i) / N))
  let T = pts(top, s0T, L)
  let B = pts(bot, L, s0B)
  if (a.rigid && !a.front) {
    T = [...runBack(T[0]!, T[1]!, 24), ...T]
    B = [...B, ...runBack(B[B.length - 1]!, B[B.length - 2]!, 24).toReversed()]
  }
  return { T, B }
}

function startOf(a: FlipperArm, start: number, L: number): number {
  if (a.front) return 0
  return a.even ? (start * L) / FLIPPER_LENGTH : start
}

function runBack(p: Point, q: Point, k: number): ReadonlyArray<Point> {
  const d = dirBetween(p, q)
  return Array.from({ length: 8 }, (_, i) => addScaled(p, d, (-k * (8 - i)) / 8))
}

function tipCap(
  a: FlipperArm,
  sp: Spine,
  T: ReadonlyArray<Point>,
  B: ReadonlyArray<Point>
): string {
  const TK = a.thick || 1
  const cap = a.shape?.cap || [9, 7]
  const capT = cap[0] * TK
  const capB = cap[1] * TK
  const end = sp.at(sp.L)
  const Tt = T[T.length - 1]!
  const Tb = B[0]!
  const tT = a.shape ? dirBetween(T[T.length - 2]!, Tt) : end.dir
  const tB = a.shape ? dirBetween(B[1]!, Tb) : end.dir
  return `C${f2(Tt[0] + tT[0] * capT)} ${f2(Tt[1] + tT[1] * capT)} ${f2(Tb[0] + tB[0] * capB)} ${f2(Tb[1] + tB[1] * capB)} ${f2(Tb[0])} ${f2(Tb[1])}`
}

const quadPts = (a: Point, c: Point, b: Point): Array<Point> =>
  Array.from({ length: 9 }, (_, i) => {
    const u = i / 8
    const k = (j: 0 | 1): number => (1 - u) ** 2 * a[j] + 2 * u * (1 - u) * c[j] + u * u * b[j]
    return [k(0), k(1)]
  })

const cubicPts = (a: Point, c: Point, d: Point, b: Point): Array<Point> =>
  Array.from({ length: 11 }, (_, i) => {
    const u = i / 10
    const k = (j: 0 | 1): number =>
      (1 - u) ** 3 * a[j] + 3 * u * (1 - u) ** 2 * c[j] + 3 * u * u * (1 - u) * d[j] + u ** 3 * b[j]
    return [k(0), k(1)]
  })

class EdgeJoin {
  constructor(
    private readonly a: FlipperArm,
    private readonly ex: (y: number) => number
  ) {}

  join(pts: ReadonlyArray<Point>, along: number, fr: number): ReadonlyArray<Point> {
    const k = pts.findIndex((p) => this.outside(p))
    if (k === -1) return this.fromInside(pts)
    if (k === 0) return this.fromOutside(pts, along)
    return this.crossing(pts, k, along, fr)
  }

  private outside(p: Point): boolean {
    return this.a.side * (p[0] - this.ex(p[1])) > 0.5
  }

  private fromInside(pts: ReadonlyArray<Point>): ReadonlyArray<Point> {
    const sd = this.a.side
    const P = pts[0]!
    const t = dirBetween(P, pts[1]!)
    const A: Point = [this.ex(P[1]), P[1]]
    return [...cubicPts(A, [A[0] - sd * 4, A[1]], addScaled(P, t, -4), P), ...pts.slice(1)]
  }

  private fromOutside(pts: ReadonlyArray<Point>, along: number): ReadonlyArray<Point> {
    const sd = this.a.side
    const P = pts[0]!
    const t = dirBetween(P, pts[1]!)
    const lam = Math.abs(t[0]) > 0.15 ? (P[0] - this.ex(P[1])) / t[0] : -1
    if (lam > 0.5 && lam < 14) {
      const C = addScaled(P, t, -lam)
      const f = Math.min(9, 0.8 * lam)
      const Ay = C[1] + along * f
      return [...quadPts([this.ex(Ay), Ay], C, addScaled(C, t, f)), ...pts]
    }
    const j = pts.findIndex((q) => !this.outside(q))
    if (sd * t[0] < 0 && j > 0) return [this.crossingPoint(pts[j - 1]!, pts[j]!), ...pts.slice(j)]
    const Ay = P[1] + along * 8
    const A: Point = [this.ex(Ay), Ay]
    return [...cubicPts(A, [A[0], A[1] - along * 6], addScaled(P, t, -5), P), ...pts.slice(1)]
  }

  private crossing(
    pts: ReadonlyArray<Point>,
    k: number,
    along: number,
    fr: number
  ): ReadonlyArray<Point> {
    const p0 = pts[k - 1]!
    const p1 = pts[k]!
    let left = 0
    for (let i = k; i < pts.length - 1; i++)
      left += Math.hypot(pts[i + 1]![0] - pts[i]![0], pts[i + 1]![1] - pts[i]![1])
    const X = this.crossingPoint(p0, p1)
    const t = dirBetween(p0, p1)
    const f = Math.min(this.a.rigid ? fr : 12, left / 3)
    const Ay = X[1] + along * f
    const m = pts.findIndex((q, i) => i >= k && Math.hypot(q[0] - X[0], q[1] - X[1]) >= f)
    if (m < 0) return quadPts([this.ex(Ay), Ay], X, addScaled(X, t, f))
    return [...quadPts([this.ex(Ay), Ay], X, pts[m]!), ...pts.slice(m + 1)]
  }

  private crossingPoint(p0: Point, p1: Point): Point {
    const sd = this.a.side
    const d0 = sd * (p0[0] - this.ex(p0[1]))
    const d1 = sd * (p1[0] - this.ex(p1[1]))
    const u = d0 / (d0 - d1)
    return [p0[0] + (p1[0] - p0[0]) * u, p0[1] + (p1[1] - p0[1]) * u]
  }
}
