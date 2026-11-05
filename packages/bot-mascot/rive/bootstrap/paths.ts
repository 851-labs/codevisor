import type { Pt } from "./collect.js"
import type { Contour, Vertex } from "./svg.js"

export type EndHandle = Pt | "corner"

export interface Ends {
  readonly first: EndHandle
  readonly last: EndHandle
}

export interface Trace {
  readonly points: ReadonlyArray<Pt>
  readonly at: ReadonlyArray<number>
}

const SEGMENT_SAMPLES = 16
const BEND_WEIGHT = 14
const CORNER_TURN = 0.9

export function runVertices(run: ReadonlyArray<Pt>, count: number, ends: Ends): Vertex[] {
  const arc = cumulative(run)
  const corners = cornerArcs(run, arc, Math.floor(count / 3))
  const at = samplePositions(run, arc, count, corners)
  const pts = at.map((s) => pointAt(run, arc, s))
  return pts.map((p, k) => {
    if (corners.includes(at[k])) return { p, inH: p, outH: p }

    const prev = pts[Math.max(0, k - 1)]
    const next = pts[Math.min(count - 1, k + 1)]
    const t = unit([next[0] - prev[0], next[1] - prev[1]])
    const before = Math.hypot(p[0] - prev[0], p[1] - prev[1])
    const after = Math.hypot(next[0] - p[0], next[1] - p[1])
    const inH = handleOr(k === 0 ? ends.first : undefined, p, along(p, t, -before / 3))
    const outH = handleOr(k === count - 1 ? ends.last : undefined, p, along(p, t, after / 3))
    return { p, inH, outH }
  })
}

function cornerArcs(run: ReadonlyArray<Pt>, arc: ReadonlyArray<number>, limit: number): number[] {
  const turns = run.map((_, i) => (i > 0 && i < run.length - 1 ? turnAt(run, i) : 0))
  const peak = (i: number) =>
    turns[i] > CORNER_TURN && turns[i] >= (turns[i - 1] ?? 0) && turns[i] >= (turns[i + 1] ?? 0)
  return turns
    .flatMap((_, i) => (peak(i) ? [i] : []))
    .toSorted((a, b) => turns[b] - turns[a])
    .slice(0, limit)
    .map((i) => arc[i])
    .toSorted((a, b) => a - b)
}

function samplePositions(
  run: ReadonlyArray<Pt>,
  arc: ReadonlyArray<number>,
  count: number,
  corners: ReadonlyArray<number>
): number[] {
  const weighted = bendWeighted(run, arc)
  const total = weighted[weighted.length - 1] || 1
  const free = count - corners.length
  const even = Array.from({ length: free }, (_, k) =>
    arcAt(weighted, arc, (total * k) / (free - 1))
  )
  return [...even, ...corners].toSorted((a, b) => a - b)
}

const along = (p: Pt, t: Pt, d: number): Pt => [p[0] + t[0] * d, p[1] + t[1] * d]

const unit = (v: Pt): Pt => {
  const len = Math.hypot(v[0], v[1]) || 1
  return [v[0] / len, v[1] / len]
}

function bendWeighted(run: ReadonlyArray<Pt>, arc: ReadonlyArray<number>): number[] {
  const out = [0]
  for (let i = 1; i < run.length; i++) {
    const turn = i < run.length - 1 ? turnAt(run, i) : 0
    out.push(out[i - 1] + (arc[i] - arc[i - 1]) + BEND_WEIGHT * turn)
  }
  return out
}

function turnAt(run: ReadonlyArray<Pt>, i: number): number {
  const a = run[i - 1]
  const b = run[i]
  const c = run[i + 1]
  const t0 = Math.atan2(b[1] - a[1], b[0] - a[0])
  const t1 = Math.atan2(c[1] - b[1], c[0] - b[0])
  return Math.abs(Math.atan2(Math.sin(t1 - t0), Math.cos(t1 - t0)))
}

function arcAt(weighted: ReadonlyArray<number>, arc: ReadonlyArray<number>, w: number): number {
  let i = 1
  while (i < weighted.length - 1 && weighted[i] < w) i++
  const u = Math.max(0, Math.min(1, (w - weighted[i - 1]) / (weighted[i] - weighted[i - 1] || 1)))
  return arc[i - 1] + (arc[i] - arc[i - 1]) * u
}

export function cumulative(run: ReadonlyArray<Pt>): number[] {
  const out = [0]
  for (let i = 1; i < run.length; i++)
    out.push(out[i - 1] + Math.hypot(run[i][0] - run[i - 1][0], run[i][1] - run[i - 1][1]))
  return out
}

export function trace(contour: Contour): Trace {
  const vs = contour.vertices
  const count = contour.closed ? vs.length : vs.length - 1
  const points: Pt[] = [vs[0].p]
  for (let i = 0; i < count; i++) {
    const v = vs[i]
    const w = vs[(i + 1) % vs.length]
    for (let k = 1; k <= SEGMENT_SAMPLES; k++)
      points.push(cubicAt(v.p, v.outH ?? v.p, w.inH ?? w.p, w.p, k / SEGMENT_SAMPLES))
  }
  const arc = cumulative(points)
  const total = arc[arc.length - 1] || 1
  return { points, at: arc.map((a) => a / total) }
}

export const segmentEnd = (t: Trace, segments: number): number =>
  t.at[Math.min(t.at.length - 1, segments * SEGMENT_SAMPLES)]

export function nearestAt(t: Trace, q: Pt): number {
  let best = 0
  let bd = Infinity
  t.points.forEach((p, i) => {
    const d = (p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2
    if (d < bd) {
      bd = d
      best = i
    }
  })
  return t.at[best]
}

const handleOr = (end: EndHandle | undefined, p: Pt, smooth: Pt): Pt => {
  if (end === undefined) return smooth
  if (end === "corner") return [p[0], p[1]]
  return end
}

function pointAt(run: ReadonlyArray<Pt>, arc: ReadonlyArray<number>, at: number): Pt {
  let i = 1
  while (i < run.length - 1 && arc[i] < at) i++
  const a = run[i - 1]
  const b = run[i]
  const u = Math.max(0, Math.min(1, (at - arc[i - 1]) / (arc[i] - arc[i - 1] || 1)))
  return [a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u]
}

function cubicAt(p0: Pt, p1: Pt, p2: Pt, p3: Pt, u: number): Pt {
  const v = 1 - u
  const k = (m: 0 | 1) =>
    v ** 3 * p0[m] + 3 * v * v * u * p1[m] + 3 * v * u * u * p2[m] + u ** 3 * p3[m]
  return [k(0), k(1)]
}
