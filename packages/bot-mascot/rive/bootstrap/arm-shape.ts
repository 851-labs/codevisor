import { armEdges } from "../../src/arms/arm-edges.js"
import type { RigArm } from "../../src/arms/rig-arm.js"
import type { Pt } from "./collect.js"
import { cumulative, runVertices } from "./paths.js"
import type { Contour, Vertex } from "./svg.js"

export interface Ring {
  readonly top: ReadonlyArray<Pt>
  readonly under: ReadonlyArray<Pt>
  readonly back: ReadonlyArray<Pt>
}

export const TOP_POINTS = 16
export const UNDER_POINTS = 16
export const BACK_POINTS = 6
export const ARM_VERTICES = TOP_POINTS + UNDER_POINTS + BACK_POINTS
export const RING_SEGMENTS = TOP_POINTS + UNDER_POINTS - 1

const CAP_NUMBERS = /-?\d+(\.\d+)?/g

export function armContour(ring: Ring, arm: RigArm, side: number): Contour {
  const cap = capHandles(arm, side)
  const vertices = [
    ...runVertices(ring.top, TOP_POINTS, { first: "corner", last: cap.top }),
    ...runVertices(ring.under, UNDER_POINTS, { first: cap.under, last: "corner" }),
    ...backVertices(ring)
  ]
  return { closed: true, vertices }
}

function backVertices(ring: Ring): Vertex[] {
  const endUnder = ring.under[ring.under.length - 1]
  const path = [endUnder, ...ring.back, ring.top[0]]
  const arc = cumulative(path)
  const total = arc[arc.length - 1]
  return Array.from({ length: BACK_POINTS }, (_, k) => {
    const p = pointOn(path, arc, (total * (k + 1)) / (BACK_POINTS + 1))
    return { p, inH: p, outH: p }
  })
}

function pointOn(path: ReadonlyArray<Pt>, arc: ReadonlyArray<number>, at: number): Pt {
  let i = 1
  while (i < path.length - 1 && arc[i] < at) i++
  const u = Math.max(0, Math.min(1, (at - arc[i - 1]) / (arc[i] - arc[i - 1] || 1)))
  return [
    path[i - 1][0] + (path[i][0] - path[i - 1][0]) * u,
    path[i - 1][1] + (path[i][1] - path[i - 1][1]) * u
  ]
}

interface CapHandles {
  readonly top: Pt
  readonly under: Pt
}

function capHandles(arm: RigArm, side: number): CapHandles {
  const n = (armEdges(arm, side).cap.match(CAP_NUMBERS) ?? []).map(Number)
  return { top: [n[0], n[1]], under: [n[2], n[3]] }
}
