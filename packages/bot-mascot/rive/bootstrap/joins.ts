import { armLine } from "../../src/arms/arm-lines.js"
import {
  armPolygon,
  mouthMid,
  silhouette,
  snapToOutline,
  type Silhouette
} from "../../src/arms/arm-silhouette.js"
import {
  area,
  circle,
  difference,
  fromClip,
  intersection,
  offset,
  union,
  type ClipPaths
} from "../../src/arms/clip.js"
import { drawArm, type ArmDrawing } from "../../src/arms/draw-arm.js"
import { densePoly, signedDistance, type Poly } from "../../src/arms/outline-poly.js"
import type { RigArm } from "../../src/arms/rig-arm.js"
import { palette } from "../../src/color/palette.js"
import { armContour, RING_SEGMENTS, type Ring } from "./arm-shape.js"
import type { Pt } from "./collect.js"
import { nearestAt, runVertices, segmentEnd, trace } from "./paths.js"
import type { Contour, Vertex } from "./svg.js"

export interface PosedSide {
  readonly side: number
  readonly arm: RigArm
}

export interface LineTrim {
  readonly start: number
  readonly end: number
}

export interface UnionJoin {
  readonly contour: Contour
  readonly line: Contour
}

export interface ArmJoin {
  readonly contour: Contour
  readonly lines: ReadonlyArray<LineTrim>
  readonly union: UnionJoin | null
}

export const LINE_SLOTS = 2
export const UNION_POINTS = 48
export const UNION_LINE_POINTS = UNION_POINTS - 2

const OUTLINE_REACH = 110
const UNION_REACH = 110
const MARGIN = 30
const DEVIATION = 0.3
const MAX_GAP = 1
const SEAM_CLOSE = 1.5
const CREVICE = 6
const CREVICE_REACH = 40
const NOISE = 0.02
const INSET = 12
const SPIKE_TURN = 2.6
const BODY_CENTRE_X = 250
const RUN = /M([^M]+)/g

export function armJoins(body: string, posed: ReadonlyArray<PosedSide>): ArmJoin[] {
  const c = composite(body, posed)
  return posed.map((p, i) => {
    const contour = armContour(ringOf(c.drawings[i], c.snapped[i]), p.arm, p.side)
    return {
      contour,
      lines: lineTrims(contour, runsOf(c, i)),
      union: unionNear(c.sil.shape, c.mouths[i], c.poly)
    }
  })
}

interface Composite {
  readonly drawings: ReadonlyArray<ArmDrawing>
  readonly mouths: ReadonlyArray<Pt>
  readonly poly: Poly
  readonly snapped: ReadonlyArray<ReadonlyArray<readonly [number, number]>>
  readonly polygons: ReadonlyArray<ClipPaths>
  readonly sil: Silhouette
}

function composite(body: string, posed: ReadonlyArray<PosedSide>): Composite {
  const drawings = posed.map((p) => drawArm(body, p.arm, p.side, palette("sunny"), "g", "a", false))
  const mouths = drawings.map((d): Pt => {
    const m = mouthMid(d)
    return [m[0], m[1]]
  })
  const poly = outlineNear(body, mouths)
  const snapped = drawings.map((d, i) => snapToOutline(body, poly, d.poly, mouths[i]))
  const polygons = snapped.map(armPolygon)
  return {
    drawings,
    mouths,
    poly,
    snapped,
    polygons,
    sil: silhouette(poly, polygons, mouths, false)
  }
}

function runsOf(c: Composite, i: number): Pt[][] {
  const context = { poly: c.poly, keep: c.sil.keep, inShape: c.sil.inShape, armPolys: c.polygons }
  const ring = c.snapped[i].slice(0, c.drawings[i].ring.length)
  return parseRuns(armLine(context, ring, c.drawings[i].ends))
}

const outlineNear = (body: string, mouths: ReadonlyArray<Pt>): Poly =>
  densePoly(
    body,
    mouths.map((m) => [m[0], m[1], OUTLINE_REACH] as const)
  )

function ringOf(d: ArmDrawing, snapped: ReadonlyArray<readonly [number, number]>): Ring {
  const pts = snapped.map((p): Pt => [p[0], p[1]])
  const ring = pts.slice(0, d.ring.length)
  return {
    top: ring.slice(0, d.nT),
    under: ring.slice(d.nT + d.NC),
    back: pts.slice(d.ring.length)
  }
}

function parseRuns(d: string): Pt[][] {
  return [...d.matchAll(RUN)].map((m) =>
    m[1].split("L").map((pair): Pt => {
      const [x, y] = pair.trim().split(/\s+/).map(Number)
      return [x, y]
    })
  )
}

function lineTrims(contour: Contour, runs: ReadonlyArray<ReadonlyArray<Pt>>): LineTrim[] {
  const t = trace(contour)
  const ringEnd = segmentEnd(t, RING_SEGMENTS)
  return runs
    .map((run) => {
      const a = Math.min(ringEnd, nearestAt(t, run[0]))
      const b = Math.min(ringEnd, nearestAt(t, run[run.length - 1]))
      return { start: Math.min(a, b), end: Math.max(a, b) }
    })
    .filter((trim) => trim.end > trim.start)
    .slice(0, LINE_SLOTS)
    .toSorted((x, y) => x.start - y.start)
}

function unionNear(outlined: ClipPaths, mouth: Pt, body: Poly): UnionJoin | null {
  const shape = crevicesClosed(outlined, mouth)
  const run =
    deviating(localRun(outline(shape), mouth), body) ??
    deviating(localRun(outline(seamsClosed(shape)), mouth), body)
  if (!run) return null

  const line = runVertices(run, UNION_LINE_POINTS, { first: "corner", last: "corner" })
  return {
    contour: { closed: true, vertices: [inward(run[0]), ...line, inward(run[run.length - 1])] },
    line: { closed: false, vertices: line }
  }
}

function deviating(run: ReadonlyArray<Pt>, body: Poly): Pt[] | null {
  const off = run.flatMap((p, i) => (Math.abs(signedDistance(body, p).d) > DEVIATION ? [i] : []))
  if (!off.length) return null

  const from = Math.max(0, off[0] - MARGIN)
  const to = Math.min(run.length - 1, off[off.length - 1] + MARGIN)
  return run.slice(from, to + 1)
}

function inward(p: Pt): Vertex {
  const q: Pt = [p[0] + Math.sign(BODY_CENTRE_X - p[0]) * INSET, p[1]]
  return { p: q, inH: q, outH: q }
}

function crevicesClosed(shape: ClipPaths, mouth: Pt): ClipPaths {
  const closed = offset(offset(shape, CREVICE), -CREVICE)
  const deep = difference(closed, offset(shape, NOISE))
  const crevices = intersection(deep, [circle(mouth, CREVICE_REACH)])
  return union(shape, offset(crevices, 2 * NOISE))
}

function seamsClosed(shape: ClipPaths): ClipPaths {
  if (shape.length < 2) return shape
  const [main, ...islands] = shape.toSorted((a, b) => Math.abs(area(b)) - Math.abs(area(a)))
  return union([main!], offset(islands, SEAM_CLOSE))
}

function outline(shape: ClipPaths): Pt[] {
  const largest = shape.toSorted((a, b) => Math.abs(area(b)) - Math.abs(area(a)))[0] ?? []
  return densified(withoutSpikes(fromClip(largest).map((p): Pt => [p[0], p[1]])))
}

function withoutSpikes(pts: ReadonlyArray<Pt>): Pt[] {
  const out = [...pts]
  let i = 0
  while (i < out.length && out.length > 3) {
    if (reverses(out, i)) {
      out.splice(i, 1)
      i = Math.max(0, i - 1)
      continue
    }
    i++
  }
  return out
}

function reverses(pts: ReadonlyArray<Pt>, i: number): boolean {
  const n = pts.length
  const a = pts[(i - 1 + n) % n]
  const b = pts[i]
  const c = pts[(i + 1) % n]
  const t0 = Math.atan2(b[1] - a[1], b[0] - a[0])
  const t1 = Math.atan2(c[1] - b[1], c[0] - b[0])
  return Math.abs(Math.atan2(Math.sin(t1 - t0), Math.cos(t1 - t0))) > SPIKE_TURN
}

function densified(pts: ReadonlyArray<Pt>): Pt[] {
  return pts.flatMap((p, i) => {
    const q = pts[(i + 1) % pts.length]
    const steps = Math.max(1, Math.ceil(Math.hypot(q[0] - p[0], q[1] - p[1]) / MAX_GAP))
    return Array.from({ length: steps }, (_, k): Pt => [
      p[0] + ((q[0] - p[0]) * k) / steps,
      p[1] + ((q[1] - p[1]) * k) / steps
    ])
  })
}

function localRun(pts: ReadonlyArray<Pt>, mouth: Pt): Pt[] {
  const n = pts.length
  const near = (i: number) => {
    const p = pts[((i % n) + n) % n]
    return Math.hypot(p[0] - mouth[0], p[1] - mouth[1]) <= UNION_REACH
  }
  let centre = 0
  pts.forEach((p, i) => {
    const c = pts[centre]
    if (Math.hypot(p[0] - mouth[0], p[1] - mouth[1]) < Math.hypot(c[0] - mouth[0], c[1] - mouth[1]))
      centre = i
  })
  let from = centre
  let to = centre
  while (to - from < n - 1 && near(from - 1)) from--
  while (to - from < n - 1 && near(to + 1)) to++
  return Array.from({ length: to - from + 1 }, (_, k) => pts[(((from + k) % n) + n) % n])
}
