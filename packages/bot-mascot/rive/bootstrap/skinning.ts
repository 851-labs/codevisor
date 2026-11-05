import type { BotMascotPose } from "../../src/pose.js"
import type { Pt } from "./collect.js"
import { planned } from "./colors.js"
import { asContours } from "./emit.js"
import { FEET, PIVOT, body, mainBodyPart, noMakeup, render, s01 } from "./parts.js"

export interface VertexTarget {
  readonly index: number
  readonly p: Pt
}

export const unzone = (y: number): number => {
  let lo = -200
  let hi = 700
  for (let i = 0; i < 60; i++) {
    const mid = (lo + hi) / 2
    if (body.zoneY(mid) < y) lo = mid
    else hi = mid
  }
  return (lo + hi) / 2
}

export const upperWeight = ([, y]: Pt): number => s01((360 - unzone(y)) / 80)

const BIND: Pt = [FEET[0], PIVOT[1]]
const BAND_TOP = 190
const BAND_BOTTOM = 392
const TOP_RAMP = 80
const BOTTOM_RAMP = 18
const SIDE_GAP = 40
const ENDPOINT = /([-\d.]+)[ ,]([-\d.]+)(?=C|Z|$)/

let restPoints: ReadonlyArray<Pt> | null = null

export const shoulderBand = (): ReadonlyArray<number> =>
  rest().flatMap((p, i) => (inBand(p) ? [i] : []))

export function restTargets(): VertexTarget[] {
  return shoulderBand().map((index) => ({ index, p: rest()[index] }))
}

export function shoulderTargets(pose: BotMascotPose, drawnBody: string): VertexTarget[] {
  const drawn = vertices(drawnBody)
  const lean = leanOf(((pose.tilt ?? 0) * Math.PI) / 180)
  return shoulderBand().map((index) => {
    const r = rest()[index]
    const bound = unskinned(drawn[index], quantized(upperWeight(r)), lean)
    const k = ramp(r)
    return { index, p: [r[0] + k * (bound[0] - r[0]), r[1] + k * (bound[1] - r[1])] }
  })
}

function rest(): ReadonlyArray<Pt> {
  restPoints ??= asContours(
    planned("body/body", mainBodyPart)(render({ makeup: noMakeup }))[1].geometry
  )[0].vertices.map((v) => v.p)
  return restPoints
}

const inBand = ([x, y]: Pt): boolean =>
  y > BAND_TOP && y < BAND_BOTTOM && Math.abs(x - FEET[0]) > SIDE_GAP

const ramp = ([, y]: Pt): number =>
  s01((y - BAND_TOP) / TOP_RAMP) * s01((BAND_BOTTOM - y) / BOTTOM_RAMP)

const quantized = (w: number): number => Math.round(255 * w) / 255

function vertices(path: string): Pt[] {
  const parts = path.split("C")
  const first = parts[0].replace("M", "").trim().split(/[ ,]+/).map(Number)
  const tail = parts.slice(1).map((seg): Pt => {
    const m = ENDPOINT.exec(seg.trim().replace(/Z$/, ""))
    return m ? [Number(m[1]), Number(m[2])] : [0, 0]
  })
  return [[first[0], first[1]], ...tail]
}

interface Lean {
  readonly c: number
  readonly s: number
  readonly t: Pt
}

function leanOf(theta: number): Lean {
  const c = Math.cos(theta)
  const s = Math.sin(theta)
  const origin: Pt = [FEET[0] + s, PIVOT[1] + 1 - c]
  return {
    c,
    s,
    t: [origin[0] - (c * BIND[0] - s * BIND[1]), origin[1] - (s * BIND[0] + c * BIND[1])]
  }
}

function unskinned(target: Pt, w: number, lean: Lean): Pt {
  const a = 1 - w + w * lean.c
  const b = -w * lean.s
  const c = w * lean.s
  const d = 1 - w + w * lean.c
  const x = target[0] - w * lean.t[0]
  const y = target[1] - w * lean.t[1]
  const det = a * d - b * c
  return [(d * x - b * y) / det, (a * y - c * x) / det]
}
