import type { Body } from "../body/zones.js"
import { clamp, lerp2, polylineD, quadraticPoint, type Point } from "../geometry/math.js"
import type { Dangle } from "../outfits/outfits.js"
import { anchorAt, plumb, type AnchorPose } from "./anchors.js"

export interface SkirtSpec {
  readonly waist: number | ((x: number) => number)
  readonly x0: number
  readonly x1: number
  readonly hem: number
  readonly grow: number
  readonly scallops: number
  readonly amp: number
  readonly from?: number
  readonly round?: boolean
  readonly bell?: number
  readonly drop?: number
}

export interface Skirt {
  readonly d: string
  readonly waistAt: (u: number) => Point
  readonly hemAt: (u: number) => Point
}

export interface Strip {
  readonly left: ReadonlyArray<Point>
  readonly right: ReadonlyArray<Point>
  readonly flop: number
}

export interface DrapeContext {
  readonly body: Body
  readonly pose: AnchorPose
  readonly tips: ReadonlyArray<Point> | undefined
  readonly dangles: ReadonlyArray<Dangle>
}

const HEM_STEPS = 132

export function skirt(ctx: DrapeContext, spec: SkirtSpec): Skirt {
  const { body, pose } = ctx
  const { x0, x1, hem, grow, from = 0, drop = 0 } = spec
  const waist = spec.waist
  const wy = typeof waist === "function" ? waist : (): number => waist
  const WL = anchorAt(body, pose, [x0, wy(x0)])
  const WR = anchorAt(body, pose, [x1, wy(x1)])
  const Lt = grown(WL, tipOf(ctx, 0), grow, drop)
  const Rt = grown(WR, tipOf(ctx, 1), grow, drop)
  const M = anchorAt(body, pose, [250, hem + drop])
  const C: Point = [2 * M[0] - (Lt[0] + Rt[0]) / 2, 2 * M[1] - (Lt[1] + Rt[1]) / 2]
  const hemAt = (u: number): Point => quadraticPoint(Lt, C, Rt, u)
  const waistAt = (u: number): Point => {
    const x = x0 + (x1 - x0) * u
    return anchorAt(body, pose, [x, wy(x)])
  }
  const hemPts = hemPoints(hemAt, spec)
  if (from > 0)
    return {
      d: polylineD([...trimTop(waistAt, hemAt, from), ...hemPts.toReversed()]),
      waistAt,
      hemAt
    }

  const waistPts: Array<Point> = []
  for (let i = 0; i <= 24; i++) waistPts.push(waistAt(i / 24))
  const bell = spec.bell ?? 0
  const outline = [
    ...waistPts,
    ...skirtSide(WR, Rt, 1, bell),
    ...hemPts.toReversed(),
    ...skirtSide(WL, Lt, -1, bell).toReversed()
  ]
  return { d: polylineD(outline), waistAt, hemAt }
}

export function strip(S: Point, T: Point, L: number, hw: (u: number) => number, end = 1): Strip {
  const len = Math.hypot(T[0] - S[0], T[1] - S[1])
  const flop = clamp(1 - len / L, 0, 0.6)
  const C: Point = [S[0], S[1] + len * 0.45]
  const left: Array<Point> = []
  const right: Array<Point> = []
  for (let i = 0; i <= 12; i++) {
    const u = (i / 12) * end
    const p = quadraticPoint(S, C, T, u)
    const n = stripNormal(S, C, T, u)
    const w = hw(u) * (1 + flop * 0.6)
    left.push([p[0] + n[0] * w, p[1] + n[1] * w])
    right.push([p[0] - n[0] * w, p[1] - n[1] * w])
  }
  return { left, right, flop }
}

export function tipOf(ctx: DrapeContext, i: number): Point {
  return ctx.tips?.[i] || plumb(ctx.body, ctx.pose, ctx.dangles[i]!)
}

function grown(W: Point, tip: Point, grow: number, drop: number): Point {
  return [W[0] + (tip[0] - W[0]) * grow, W[1] + (tip[1] - W[1]) * grow + drop]
}

function hemPoints(hemAt: (u: number) => Point, spec: SkirtSpec): ReadonlyArray<Point> {
  const { scallops, amp, round = false } = spec
  const pts: Array<Point> = []
  for (let i = 0; i <= HEM_STEPS; i++) {
    const u = i / HEM_STEPS
    const sn = Math.abs(Math.sin(Math.PI * scallops * u))
    const p = hemAt(u)
    const bump = scallops ? amp * (round ? Math.sqrt(sn) : sn) : 0
    pts.push([p[0], p[1] + bump])
  }
  return pts
}

function trimTop(
  waistAt: (u: number) => Point,
  hemAt: (u: number) => Point,
  from: number
): ReadonlyArray<Point> {
  const top: Array<Point> = []
  for (let i = 0; i <= 48; i++) top.push(lerp2(waistAt(i / 48), hemAt(i / 48), from))
  return top
}

function skirtSide(W: Point, T: Point, sg: number, bell: number): ReadonlyArray<Point> {
  const a: Array<Point> = []
  const dx = T[0] - W[0]
  const dy = T[1] - W[1]
  const n = Math.hypot(dx, dy) || 1
  for (let i = 1; i < 8; i++) {
    const t = i / 8
    const b = bell * Math.sin(Math.PI * t)
    a.push([W[0] + dx * t + sg * (dy / n) * b, W[1] + dy * t - sg * (dx / n) * b])
  }
  return a
}

function stripNormal(S: Point, C: Point, T: Point, u: number): Point {
  const tx = 2 * (1 - u) * (C[0] - S[0]) + 2 * u * (T[0] - C[0])
  const ty = 2 * (1 - u) * (C[1] - S[1]) + 2 * u * (T[1] - C[1])
  const m = Math.hypot(tx, ty) || 1
  return [-ty / m, tx / m]
}
