import { clamp, type Point } from "../geometry/math.js"

export type Poly = ReadonlyArray<Point>

export interface SignedDistance {
  readonly d: number
  readonly n: Point
  readonly q: Point
}

export type NearCircle = readonly [number, number, number]

const CACHE_LIMIT = 60
const coarseCache = new Map<string, Poly>()
const denseCache = new Map<string, Poly>()
const TOKENS = /[MLCZmlcz]|-?\d*\.?\d+(?:e-?\d+)?/g
const COMMAND = /[A-Za-z]/

type CubicSampler = (p0: Point, p1: Point, p2: Point, p3: Point, out: Array<Point>) => void

export function outlinePoly(d: string): Poly {
  const cached = coarseCache.get(d)
  if (cached) return cached
  const pts = flatten(d, (p0, p1, p2, p3, out) => {
    out.push(
      [
        0.125 * p0[0] + 0.375 * p1[0] + 0.375 * p2[0] + 0.125 * p3[0],
        0.125 * p0[1] + 0.375 * p1[1] + 0.375 * p2[1] + 0.125 * p3[1]
      ],
      p3
    )
  })
  if (coarseCache.size > CACHE_LIMIT) coarseCache.clear()
  coarseCache.set(d, pts)
  return pts
}

export function densePoly(d: string, near?: ReadonlyArray<NearCircle>): Poly {
  const key = near ? d + near.map((q) => q.map((v) => v.toFixed(1)).join(",")).join(";") : d
  const cached = denseCache.get(key)
  if (cached) return cached
  const pts = flatten(d, (p0, p1, p2, p3, out) => {
    const K = isNear(near, p0, p1, p2, p3) ? 24 : 6
    for (let k = 1; k <= K; k++) {
      const u = k / K
      const v = 1 - u
      const at = (m: 0 | 1): number =>
        v ** 3 * p0[m] + 3 * v * v * u * p1[m] + 3 * v * u * u * p2[m] + u ** 3 * p3[m]
      out.push([at(0), at(1)])
    }
  })
  if (denseCache.size > CACHE_LIMIT) denseCache.clear()
  denseCache.set(key, pts)
  return pts
}

export function inside(poly: Poly, p: Point): boolean {
  let c = false
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const a = poly[i]!
    const b = poly[j]!
    if (
      a[1] > p[1] !== b[1] > p[1] &&
      p[0] < ((b[0] - a[0]) * (p[1] - a[1])) / (b[1] - a[1]) + a[0]
    )
      c = !c
  }
  return c
}

export function signedDistance(poly: Poly, p: Point): SignedDistance {
  let best = 1e18
  let bi = 0
  let bu = 0
  for (let i = 0; i < poly.length; i++) {
    const a = poly[i]!
    const b = poly[(i + 1) % poly.length]!
    const dx = b[0] - a[0]
    const dy = b[1] - a[1]
    const u = clamp(((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (dx * dx + dy * dy || 1), 0, 1)
    const x = a[0] + u * dx - p[0]
    const y = a[1] + u * dy - p[1]
    const dd = x * x + y * y
    if (dd < best) {
      best = dd
      bi = i
      bu = u
    }
  }
  const a = poly[bi]!
  const b = poly[(bi + 1) % poly.length]!
  const t: Point = [b[0] - a[0], b[1] - a[1]]
  const m = Math.hypot(...t) || 1
  let n: Point = [t[1] / m, -t[0] / m]
  const q: Point = [a[0] + bu * t[0], a[1] + bu * t[1]]
  if (inside(poly, [q[0] + n[0] * 0.6, q[1] + n[1] * 0.6])) n = [-n[0], -n[1]]
  const d = Math.sqrt(best)
  return { d: inside(poly, p) ? -d : d, n, q }
}

function isNear(
  near: ReadonlyArray<NearCircle> | undefined,
  p0: Point,
  p1: Point,
  p2: Point,
  p3: Point
): boolean {
  if (!near) return true
  const xs = [p0[0], p1[0], p2[0], p3[0]]
  const ys = [p0[1], p1[1], p2[1], p3[1]]
  const x0 = Math.min(...xs)
  const x1 = Math.max(...xs)
  const y0 = Math.min(...ys)
  const y1 = Math.max(...ys)
  return near.some(([x, y, r]) => x + r >= x0 && x - r <= x1 && y + r >= y0 && y - r <= y1)
}

function flatten(d: string, cubic: CubicSampler): Poly {
  const t = d.match(TOKENS) ?? []
  const pts: Array<Point> = []
  let i = 0
  let cmd = ""
  let cur: Point = [0, 0]
  while (i < t.length) {
    if (COMMAND.test(t[i]!)) {
      cmd = t[i++]!
      if (cmd === "Z" || cmd === "z") continue
    }
    if (cmd === "M" || cmd === "L") {
      cur = [+t[i]!, +t[i + 1]!]
      pts.push(cur)
      i += 2
    } else if (cmd === "C") {
      const p1: Point = [+t[i]!, +t[i + 1]!]
      const p2: Point = [+t[i + 2]!, +t[i + 3]!]
      const p3: Point = [+t[i + 4]!, +t[i + 5]!]
      cubic(cur, p1, p2, p3, pts)
      cur = p3
      i += 6
    } else {
      i++
    }
  }
  return pts
}
