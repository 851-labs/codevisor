import { lerp2, pointText, type Point } from "../geometry/math.js"
import { clipOpenPath, strictlyInside, type ClipPaths } from "./clip.js"
import type { Poly } from "./outline-poly.js"

export interface ArmLineContext {
  readonly poly: Poly
  readonly keep: ClipPaths
  readonly inShape: ClipPaths
  readonly armPolys: ReadonlyArray<ClipPaths>
}

interface Walk {
  readonly pts: ReadonlyArray<Point>
  readonly l: number
}

const MIN_RUN = 8
const WALK_LIMIT = 90

export const runsD = (runs: ReadonlyArray<ReadonlyArray<Point>>): string =>
  runs.map((q) => `M${q.map(pointText).join("L")}`).join("")

export function armLine(
  ctx: ArmLineContext,
  ring: ReadonlyArray<Point>,
  ends: readonly [Point, Point]
): string {
  const runs = visibleRuns(ctx, ring).map((run) => new RunJoiner(ctx, ring, ends).join(run))
  return runsD(runs)
}

function visibleRuns(
  ctx: ArmLineContext,
  pts: ReadonlyArray<Point>
): ReadonlyArray<ReadonlyArray<Point>> {
  if (!ctx.keep.length) return [pts]
  return clipOpenPath(pts, ctx.keep).filter((q) => q.length > 1 && runLength(q) >= MIN_RUN)
}

function runLength(q: ReadonlyArray<Point>): number {
  return q.reduce(
    (l, p, i) => l + (i ? Math.hypot(p[0] - q[i - 1]![0], p[1] - q[i - 1]![1]) : 0),
    0
  )
}

class RunJoiner {
  constructor(
    private readonly ctx: ArmLineContext,
    private readonly ring: ReadonlyArray<Point>,
    private readonly ends: readonly [Point, Point]
  ) {}

  join(run: ReadonlyArray<Point>): ReadonlyArray<Point> {
    const h = this.fix(run[0]!, run[Math.min(run.length - 1, 3)]!)
    const t = this.fix(run[run.length - 1]!, run[Math.max(0, run.length - 4)]!)
    return [...(h ? h.toReversed() : []), ...run, ...(t || [])]
  }

  private underArm(q: Point): boolean {
    return this.ctx.armPolys.some((ap) => strictlyInside(q, ap))
  }

  private onEdge(q: Point): boolean {
    return !strictlyInside(q, this.ctx.inShape)
  }

  private nearOutline(q: Point): number {
    const poly = this.ctx.poly
    const N0 = poly.length
    let bi = 0
    let bd = 1e18
    const consider = (j: number): void => {
      const dd = (poly[j]![0] - q[0]) ** 2 + (poly[j]![1] - q[1]) ** 2
      if (dd < bd) {
        bd = dd
        bi = j
      }
    }
    for (let i = 0; i < N0; i += 4) consider(i)
    for (let i = bi - 4; i <= bi + 4; i++) consider((i + N0) % N0)
    return bi
  }

  private walk(P: Point, st: number): Walk | null {
    const poly = this.ctx.poly
    const N0 = poly.length
    const out: Array<Point> = []
    let prev = P
    let i = this.nearOutline(P)
    let l = 0
    let cost = 0
    for (let g = 0; g < N0 && l < WALK_LIMIT; g++) {
      i = (i + st + N0) % N0
      const q = poly[i]!
      const seg = Math.hypot(q[0] - prev[0], q[1] - prev[1])
      const n = Math.max(1, Math.ceil(seg))
      for (let k = 1; k <= n; k++) {
        const r = lerp2(prev, q, k / n)
        const ua = this.underArm(r)
        out.push(r)
        cost += (seg / n) * (ua ? 3 : 1)
        if (this.onEdge(r) && !ua) return { pts: out, l: cost }
      }
      l += seg
      prev = q
    }
    return null
  }

  private across(P: Point): ReadonlyArray<Point> | null {
    const a = this.walk(P, 1)
    const b = this.walk(P, -1)
    if (a && (!b || a.l <= b.l)) return a.pts
    return b ? b.pts : null
  }

  private nearRing(q: Point): number {
    let bi = 0
    let bd = 1e18
    this.ring.forEach((p, i) => {
      const dd = (p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2
      if (dd < bd) {
        bd = dd
        bi = i
      }
    })
    return bi
  }

  private fix(P: Point, Q: Point): ReadonlyArray<Point> | null {
    if (this.onEdge(P)) return null
    const rg = this.ring
    const i0 = this.nearRing(P)
    const st = this.nearRing(Q) > i0 ? -1 : 1
    const out: Array<Point> = []
    for (let i = i0 + st; i >= 0 && i < rg.length; i += st) {
      out.push(rg[i]!)
      if (this.onEdge(rg[i]!)) return out
    }
    const e = out.length ? out[out.length - 1]! : P
    const atEnd = this.ends.some((q) => Math.hypot(q[0] - e[0], q[1] - e[1]) < 5)
    const more = atEnd ? this.across(e) : null
    return more ? [...out, ...more] : out
  }
}
