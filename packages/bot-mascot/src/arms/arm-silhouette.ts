import { clamp, lerp2, normalize, s01, type Point } from "../geometry/math.js"
import {
  area,
  circle,
  difference,
  intersection,
  isOuter,
  offset,
  oriented,
  rectangle,
  SCALE,
  simplified,
  union,
  type ClipPaths
} from "./clip.js"
import type { ArmDrawing } from "./draw-arm.js"
import { inside, outlinePoly, signedDistance, type Poly } from "./outline-poly.js"

export interface Silhouette {
  readonly shape: ClipPaths
  readonly shapeL: ClipPaths
  readonly rawL: ClipPaths
  readonly disks: ClipPaths
  readonly added: ClipPaths
  readonly inShape: ClipPaths
  readonly keep: ClipPaths
}

const CLOSE = 10
const ROOT = 34
const NEAR = 70
const BOX = 100

export const mouthMid = (d: ArmDrawing): Point => lerp2(d.ends[0], d.ends[1], 0.5)

export function snapToOutline(
  body: string,
  poly: Poly,
  pts: ReadonlyArray<Point>,
  m: Point
): ReadonlyArray<Point> {
  const coarse = outlinePoly(body)
  const segs: Array<readonly [Point, Point]> = []
  for (let i = 0; i < poly.length; i++) {
    const a = poly[i]!
    if (Math.hypot(a[0] - m[0], a[1] - m[1]) < 90) segs.push([a, poly[(i + 1) % poly.length]!])
  }
  const rs = pts.map((q) => {
    if (Math.hypot(q[0] - m[0], q[1] - m[1]) > 70) return null
    const c = signedDistance(coarse, q).d
    return c > 3 || c < -12 ? null : nearestOnSegments(coarse, segs, q)
  })
  const w0 = pts.map((_, i) => {
    const r = rs[i]
    if (!r || r.d > 0.5) return 0
    const a = pts[Math.max(0, i - 1)]!
    const b = pts[Math.min(pts.length - 1, i + 1)]!
    const t = normalize([b[0] - a[0], b[1] - a[1]])
    return (1 - s01((-r.d - 3) / 4)) * s01((Math.abs(t[0] * r.n[1] - t[1] * r.n[0]) - 0.92) / 0.06)
  })
  return pts.map((q, i) => {
    let w = 0
    let n = 0
    for (let j = Math.max(0, i - 6); j <= Math.min(pts.length - 1, i + 6); j++) {
      w += w0[j]!
      n++
    }
    w /= n
    const r = rs[i]
    return w > 0.001 && r ? lerp2(q, r.q, Math.min(1, w)) : q
  })
}

export function silhouette(
  poly: Poly,
  armC: ReadonlyArray<ClipPaths>,
  mids: ReadonlyArray<Point>,
  withSleeve: boolean
): Silhouette {
  if (!mids.length)
    return { shape: [], shapeL: [], rawL: [], disks: [], added: [], inShape: [], keep: [] }
  const bodyD = oriented(poly)
  const boxes = mids.map((m) => rectangle(m[0] - BOX, m[1] - BOX, m[0] + BOX, m[1] + BOX))
  const bodyL = intersection(bodyD, boxes)
  const band = difference(offset(bodyL, 9, true), bodyL)
  const disks = mids.flatMap((m) => union([circle(m, ROOT)], intersection(band, [circle(m, NEAR)])))
  const roots = intersection(armC.flat(), disks)
  const rawL = union(bodyL, roots)
  const inner = mids.map((m) =>
    rectangle(m[0] - BOX + 20, m[1] - BOX + 20, m[0] + BOX - 20, m[1] + BOX - 20)
  )
  const gaps = intersection(difference(offset(offset(rawL, CLOSE), -CLOSE), rawL), inner)
  const rounds = offset(offset(gaps, -0.6), 0.6).filter(
    (pp) => Math.abs(area(pp)) > 4 * SCALE * SCALE
  )
  const shapeL = union(rawL, rounds)
  const shape = union(bodyD, union(roots, rounds)).filter(isOuter)
  const added = withSleeve ? difference(union(roots, rounds), bodyD) : []
  const inShape = shapeL.length ? offset(shapeL, -1.5) : []
  return {
    shape,
    shapeL,
    rawL,
    disks,
    added,
    inShape,
    keep: keptOutline(shape, shapeL, rawL, inShape, disks)
  }
}

export const armPolygon = (pts: ReadonlyArray<Point>): ClipPaths => simplified(pts)

function keptOutline(
  shape: ClipPaths,
  shapeL: ClipPaths,
  rawL: ClipPaths,
  inShape: ClipPaths,
  disks: ClipPaths
): ClipPaths {
  if (!shape.length) return []
  const rounds = difference(shapeL, rawL)
  const big = [rectangle(-500, -500, 1000, 1000)]
  return union(difference(inShape, offset(rounds, 1.5)), difference(big, disks))
}

interface Nearest {
  readonly d: number
  readonly q: Point
  readonly n: Point
}

function nearestOnSegments(
  coarse: Poly,
  segs: ReadonlyArray<readonly [Point, Point]>,
  q: Point
): Nearest {
  let bd = 1e18
  let bq = q
  let bt: Point = [1, 0]
  for (const [a, b] of segs) {
    const dx = b[0] - a[0]
    const dy = b[1] - a[1]
    const u = clamp(((q[0] - a[0]) * dx + (q[1] - a[1]) * dy) / (dx * dx + dy * dy || 1), 0, 1)
    const x = a[0] + u * dx
    const y = a[1] + u * dy
    const dd = (x - q[0]) ** 2 + (y - q[1]) ** 2
    if (dd < bd) {
      bd = dd
      bq = [x, y]
      bt = [dx, dy]
    }
  }
  const t = normalize(bt)
  return { d: (inside(coarse, q) ? -1 : 1) * Math.sqrt(bd), q: bq, n: [t[1], -t[0]] }
}
