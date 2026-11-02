import { data } from "../data.js"
import { catmull, fa, rotateAbout, s01, taubin, type Point } from "../geometry/math.js"
import type { BotMascotPose, LegPose } from "../pose.js"
import type { Body } from "./zones.js"

export type Side = "L" | "R"

export type RigWeights = readonly [number, number, number, number, number]

export interface Crease {
  readonly c: ReadonlyArray<Point>
  readonly op: number
}

export interface BodyOutline {
  readonly d: string
  readonly creases: ReadonlyArray<Crease>
  readonly eyeTf: string
}

export const restPoints = data.rig.points
export const hip = data.rig.hip
export const waist = data.rig.waist
export const centre = data.rig.centre

export const weigh = ([x, y]: Point): RigWeights => [
  s01((y - 322) / 34),
  s01((290 - x) / 80),
  s01((360 - y) / 80),
  s01((y - 336) / 76),
  Math.exp(-(((y - 380) / 16) ** 2))
]

const restWeights = restPoints.map(weigh)
const sides: ReadonlyArray<Side> = ["L", "R"]
const bodyKeys = ["tilt", "twist", "shift", "spin"] as const

export const isRest = (pose: BotMascotPose): boolean =>
  !bodyKeys.some((k) => Math.abs(pose[k] || 0) > 1e-4) && !sides.some((s) => legMoves(pose[s]))

export function legMap(side: Side, leg: LegPose, p: Point, foot: number, bulge: number): Point {
  const s = side === "L" ? -1 : 1
  const h = hip[side]
  let x = p[0]
  let y = p[1]
  if (leg.stretch) y = h[1] + (y - h[1]) * (1 + leg.stretch)
  if (leg.bend) {
    x += s * leg.bend * 7 * bulge
    y -= leg.bend * 9 * foot
  }
  if (leg.rot) [x, y] = rotateAbout([x, y], h, leg.rot)
  x += (leg.dx || 0) * foot
  y -= leg.lift || 0
  return [x, y]
}

export function headTf(body: Body, pose: BotMascotPose, y: number): string {
  let tf = body.zoned ? `translate(0 ${fa(-body.rise)}) ` : ""
  if (pose.spin) tf += `rotate(${fa(pose.spin)} ${centre[0]} ${centre[1]}) `
  const dx = (pose.shift || 0) + (pose.twist || 0) * 0.16 * (waist[1] - y)
  if (dx) tf += `translate(${fa(dx)} 0) `
  if (pose.tilt) tf += `rotate(${fa(pose.tilt)} ${waist[0]} ${waist[1]}) `
  return tf.trim()
}

export function deform(pose: BotMascotPose, q: Point, weights: RigWeights): Point {
  const [wLeg, sideL, wUp] = weights
  let x = q[0]
  let y = q[1]
  for (const side of sides) {
    const leg = pose[side]
    if (!leg) continue
    const w = wLeg * (side === "L" ? sideL : 1 - sideL)
    if (w <= 0) continue
    const m = legMap(side, leg, q, weights[3], weights[4])
    x += w * (m[0] - q[0])
    y += w * (m[1] - q[1])
  }
  if (pose.tilt) {
    const r = rotateAbout([x, y], waist, pose.tilt)
    x += wUp * (r[0] - x)
    y += wUp * (r[1] - y)
  }
  if (pose.twist) x += wUp * pose.twist * 0.16 * (waist[1] - y)
  if (pose.shift) x += wUp * pose.shift
  if (pose.spin) [x, y] = rotateAbout([x, y], centre, pose.spin)
  return [x, y]
}

export function bodyOutline(body: Body, pose: BotMascotPose): BodyOutline {
  const eyeTf = headTf(body, pose, data.cyclops.y)
  if (isRest(pose) && !body.zoned) return { d: data.body, creases: [], eyeTf }

  const deformed = restPoints.map((q, i) => body.zoneMap(deform(pose, q, restWeights[i]!)))
  return { d: catmull(taubin(deformed, 10)), creases: kneeCreases(pose), eyeTf }
}

function legMoves(leg: LegPose | undefined): boolean {
  return leg !== undefined && Object.values(leg).some((v) => Math.abs(v) > 1e-4)
}

function kneeCreases(pose: BotMascotPose): ReadonlyArray<Crease> {
  const creases: Array<Crease> = []
  for (const side of sides) {
    const leg = pose[side] || {}
    if ((leg.bend || 0) <= 0.04) continue
    creases.push({ c: creaseCurve(pose, side, leg), op: Math.min(1, (leg.bend || 0) * 1.4) })
  }
  return creases
}

function creaseCurve(pose: BotMascotPose, side: Side, leg: LegPose): ReadonlyArray<Point> {
  const s = side === "L" ? -1 : 1
  const rest: ReadonlyArray<Point> = [
    [250 + s * 80, 370],
    [250 + s * 72, 381],
    [250 + s * 80, 392]
  ]
  const bent = rest.map((q) =>
    legMap(side, leg, q, s01((q[1] - 336) / 76), Math.exp(-(((q[1] - 380) / 16) ** 2)))
  )
  const spin = pose.spin
  if (!spin) return bent
  return bent.map((q) => rotateAbout(q, centre, spin))
}
