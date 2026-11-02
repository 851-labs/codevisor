import { normalize, s01, subtract, type Point } from "../geometry/math.js"
import type { EdgeSample } from "./arm-edges.js"
import { dot, fromMouth, mouthEnd, type Mouth, type MouthEdge } from "./arm-mouth.js"
import { inside, signedDistance, type SignedDistance } from "./outline-poly.js"
import { ARM_LENGTH } from "./rig-arm.js"

export interface ArmRing {
  readonly endT: Point
  readonly endB: Point
  readonly topL: ReadonlyArray<EdgeSample>
  readonly botL: ReadonlyArray<EdgeSample>
  readonly top: ReadonlyArray<Point>
  readonly bot: ReadonlyArray<Point>
  readonly ring: ReadonlyArray<Point>
  readonly nT: number
  readonly NC: number
}

const CAP_POINTS = 20
const CAP_NUMBERS = /-?\d+(\.\d+)?/g

export function armRing(
  m: Mouth,
  sg: number,
  topEdge: ReadonlyArray<EdgeSample>,
  bottomEdge: ReadonlyArray<EdgeSample>,
  cap: string
): ArmRing {
  const endT = mouthEnd(m, sg, 1)
  const endB = mouthEnd(m, sg, -1)
  const mT = fromMouth(m, topEdge, endT)
  const mB = fromMouth(m, bottomEdge, endB)
  const top = mT.list.map((q) => q.p)
  const bot = mB.list.map((q) => q.p)
  const ring = [...top, ...capPoints(top[top.length - 1]!, cap), ...bot.toReversed()]
  const nT = top.length
  const layer = new RingLayer(m, ring, nT, endT, endB, mT, mB)
  layer.lay()
  unloopRange(ring, 0, nT)
  unloopRange(ring, nT + CAP_POINTS, ring.length)
  return { endT, endB, topL: mT.list, botL: mB.list, top, bot, ring, nT, NC: CAP_POINTS }
}

const orientation = (p: Point, q: Point, r: Point): number =>
  Math.sign((q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]))

export function crosses(a: Point, b: Point, c: Point, d: Point): boolean {
  const o = orientation
  return o(a, b, c) !== o(a, b, d) && o(c, d, a) !== o(c, d, b)
}

export function twists(r: ArmRing): boolean {
  const A = r.ring.slice(0, Math.min(r.nT, 70))
  const B = r.ring.slice(-Math.min(r.ring.length - r.nT - r.NC, 70))
  for (let i = 3; i < A.length; i += 3) {
    for (let k = 3; k < B.length; k += 3)
      if (crosses(A[i - 3]!, A[i]!, B[k - 3]!, B[k]!)) return true
  }
  return false
}

function capPoints(Tt: Point, cap: string): ReadonlyArray<Point> {
  const cn = (cap.match(CAP_NUMBERS) ?? []).map(Number)
  return Array.from({ length: CAP_POINTS }, (_, i): Point => {
    const u = (i + 1) / (CAP_POINTS + 1)
    const v = 1 - u
    const at = (j: 0 | 1): number =>
      v ** 3 * Tt[j] + 3 * v * v * u * cn[j]! + 3 * v * u * u * cn[2 + j]! + u ** 3 * cn[4 + j]!
    return [at(0), at(1)]
  })
}

class RingLayer {
  private readonly nR: number
  private readonly mU: Point
  private readonly mL: number
  private lieT = false
  private lieB = false

  constructor(
    private readonly m: Mouth,
    private readonly ring: Array<Point>,
    private readonly nT: number,
    private readonly endT: Point,
    endB: Point,
    private readonly mT: MouthEdge,
    private readonly mB: MouthEdge
  ) {
    this.nR = ring.length
    this.mU = subtract(endB, endT)
    this.mL = Math.hypot(...this.mU) || 1
  }

  lay(): void {
    const { ring, nR } = this
    let ar = 0
    for (let i = 0; i < nR; i++) {
      const a = ring[i]!
      const b = ring[(i + 1) % nR]!
      ar += a[0] * b[1] - b[0] * a[1]
    }
    this.lieT = this.alongAcross(1)
    this.lieB = this.alongAcross(-1)
    const keep = this.keptHeads()
    const raw = ring.map((q): Point => [q[0], q[1]])
    const steepT = this.steep(this.mT)
    const steepB = this.steep(this.mB)
    const lay = ring.map((p, i): Point => {
      if (this.inTip(i) || (i < this.nT ? steepT : steepB)) return [0, 0]
      return this.move(p, i, ar, raw, keep)
    })
    const smoothed = smoothMoves(lay)
    for (let i = 0; i < nR; i++)
      ring[i] = [ring[i]![0] + smoothed[i]![0], ring[i]![1] + smoothed[i]![1]]
  }

  private uOf(q: Point): number {
    return ((q[0] - this.endT[0]) * this.mU[0] + (q[1] - this.endT[1]) * this.mU[1]) / this.mL
  }

  private alongAcross(st: number): boolean {
    let dmax = 0
    let reach = 0
    for (let i = st > 0 ? 0 : this.nR - 1; i >= 0 && i < this.nR; i += st) {
      const r = signedDistance(this.m.poly, this.ring[i]!)
      const u = this.uOf(r.q)
      if (u < -2 || u > this.mL + 2) break
      dmax = Math.max(dmax, Math.abs(r.d))
      reach = Math.max(reach, st > 0 ? u : this.mL - u)
    }
    return reach > 0.8 * this.mL && dmax < this.m.hw
  }

  private keptHeads(): { readonly T: number; readonly B: number } {
    const nH = this.mT.list.findIndex((q) => q.s >= this.m.Sb)
    const nHb = this.mB.list.findIndex((q) => q.s >= this.m.Sb)
    const headIn = (ix: ReadonlyArray<number>): boolean =>
      ix.some((i) => signedDistance(this.m.poly, this.ring[i]!).d < -3)
    const topIx = Array.from({ length: Math.max(1, nH) }, (_, i) => i)
    const bottomIx = Array.from({ length: Math.max(1, nHb) }, (_, i) => this.nR - 1 - i)
    return { T: headIn(topIx) ? nH : 0, B: headIn(bottomIx) ? nHb : 0 }
  }

  private steep(edge: MouthEdge): boolean {
    return -(edge.dep[0] * this.m.nS[0] + edge.dep[1] * this.m.nS[1]) > 0.42
  }

  private inTip(i: number): boolean {
    const dTip = Math.min(Math.abs(i - this.nT), Math.abs(i - (this.nT + CAP_POINTS)))
    return (i >= this.nT && i < this.nT + CAP_POINTS) || dTip < 10
  }

  private offMouth(q: Point, i: number): number {
    if ((this.lieT && i < this.nT) || (this.lieB && i >= this.nT + CAP_POINTS)) return 1
    const u = this.uOf(q)
    return s01(Math.max(-u, u - this.mL) / this.m.sw)
  }

  private move(
    p: Point,
    i: number,
    ar: number,
    raw: ReadonlyArray<Point>,
    keep: { readonly T: number; readonly B: number }
  ): Point {
    const { m, ring, nR } = this
    const r = signedDistance(m.poly, p)
    const t = normalize(subtract(ring[Math.min(nR - 1, i + 1)]!, ring[Math.max(0, i - 1)]!))
    const no: Point = ar > 0 ? [t[1], -t[0]] : [-t[1], t[0]]
    const f = dot(no, r.n)
    if (f <= 0 && (i < keep.T || i > nR - 1 - keep.B)) return [0, 0]
    const reach = 2.4 * ARM_LENGTH * m.k
    const fromRoot = Math.hypot(p[0] - m.R[0], p[1] - m.R[1])
    const nearR = fromRoot < 1.6 * ARM_LENGTH * m.k
    if (fromRoot > reach || Math.hypot(r.q[0] - m.S[0], r.q[1] - m.S[1]) > reach) return [0, 0]
    if (overOwnArm(r, raw)) return [0, 0]
    const tg = f > 0 ? 0 : m.hw
    const e = f > 0 ? r.d : tg - r.d
    if (e > layLimit(f, nearR, m.hw) || e < -22) return [0, 0]
    const w = layWeight(r, t, f, e, nearR, m.hw)
    const mv = (r.d - tg) * w
    const om = this.offMouth(r.q, i)
    return [-r.n[0] * mv * om, -r.n[1] * mv * om]
  }
}

function overOwnArm(r: SignedDistance, raw: ReadonlyArray<Point>): boolean {
  const qo: Point = [r.q[0] + r.n[0] * 4, r.q[1] + r.n[1] * 4]
  return inside(raw, qo) && !raw.some((w) => Math.hypot(w[0] - qo[0], w[1] - qo[1]) < 10)
}

function layLimit(f: number, nearR: boolean, hw: number): number {
  if (f > 0) return 6
  return nearR ? hw + 8 : 0
}

function layWeight(
  r: SignedDistance,
  t: Point,
  f: number,
  e: number,
  nearR: boolean,
  hw: number
): number {
  const hair = f > 0.5 && nearR && r.d > 0 && r.d < 4
  if (hair) return 1 - s01((r.d - 2) / 2)
  return (
    gapWeight(f, e, hw) *
    s01((Math.abs(t[0] * r.n[1] - t[1] * r.n[0]) - 0.85) / 0.1) *
    s01((Math.abs(f) - 0.3) / 0.4)
  )
}

function gapWeight(f: number, e: number, hw: number): number {
  if (e < 0) return 1 - s01((-e - 12) / 10)
  if (f > 0) return 1 - s01((e - 1) / 5)
  return 1 - s01((e - hw - 3) / 5)
}

function smoothMoves(lay: ReadonlyArray<Point>): ReadonlyArray<Point> {
  const nR = lay.length
  return lay.map((v, i): Point => {
    if (i === 0 || i === nR - 1) return v
    let x = 0
    let y = 0
    let n = 0
    for (let j = Math.max(0, i - 12); j <= Math.min(nR - 1, i + 12); j++) {
      const w = 13 - Math.abs(j - i)
      x += lay[j]![0] * w
      y += lay[j]![1] * w
      n += w
    }
    return [x / n, y / n]
  })
}

function unloopRange(ring: Array<Point>, from: number, to: number): void {
  const pts = ring.slice(from, to)
  unloop(pts)
  pts.forEach((p, i) => (ring[from + i] = p))
}

function unloop(pts: Array<Point>): void {
  for (let i = 0; i < pts.length - 3; i++) {
    for (let k = Math.min(pts.length - 2, i + 80); k > i + 1; k--) {
      const X = segmentCrossing(pts[i]!, pts[i + 1]!, pts[k]!, pts[k + 1]!)
      if (!X) continue
      for (let m = i + 1; m <= k; m++) pts[m] = [X[0], X[1]]
      break
    }
  }
}

function segmentCrossing(a: Point, b: Point, c: Point, d: Point): Point | null {
  const r = subtract(b, a)
  const q = subtract(d, c)
  const den = r[0] * q[1] - r[1] * q[0]
  if (Math.abs(den) < 1e-9) return null
  const t = ((c[0] - a[0]) * q[1] - (c[1] - a[1]) * q[0]) / den
  const u = ((c[0] - a[0]) * r[1] - (c[1] - a[1]) * r[0]) / den
  return t > 0 && t < 1 && u > 0 && u < 1 ? [a[0] + r[0] * t, a[1] + r[1] * t] : null
}
