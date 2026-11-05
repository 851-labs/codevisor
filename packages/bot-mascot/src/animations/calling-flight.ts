import { s01, type Point } from "../geometry/math.js"
import { LIFT_FROM, PICK_UP, PICKED_UP } from "./calling-ground.js"
import type { PlacedProp } from "./matrix.js"

export interface PhoneFlight extends PlacedProp {
  readonly held: boolean
}

export const WIND = [6.5, 6.95] as const
export const FLING = [6.95, 7.35] as const
export const RELEASE = FLING[0] + 0.12 * (FLING[1] - FLING[0])
export const TUCK = RELEASE + 0.75
export const STILL_PHONE = "translate(0 0) rotate(0) scale(1.15)"

const MOOD_LOW = 0.4
const MOOD_EAR = 0.95
const MOOD_JOIN = 1.6
const MOOD_SETTLED = 1.496
const WIND_ROT = 18
const SPIN = -1000
const THROW: readonly [Point, Point, Point] = [
  [382, 248],
  [230, 262],
  [-150, -40]
]
const DROP = [250, 900] as const
const SWING: Point = [292, 290]
const OVER: Point = [188, 328]
const SETTLE: Point = [204, 334]
const PHONE_TRANSFORM = /translate\(([-\d.]+) ([-\d.]+)\) rotate\(([-\d.]+)\) scale\(([-\d.]+)\)/

export const warp = (t: number): number => {
  if (t < LIFT_FROM) return (MOOD_LOW * t) / LIFT_FROM
  if (t < PICKED_UP) return between(t, LIFT_FROM, PICKED_UP, MOOD_LOW, MOOD_EAR)
  if (t < PICK_UP) return between(t, PICKED_UP, PICK_UP, MOOD_EAR, MOOD_SETTLED)
  if (t < MOOD_JOIN) return between(t, PICK_UP, MOOD_JOIN, MOOD_SETTLED, MOOD_JOIN)
  return t
}

const between = (t: number, t0: number, t1: number, w0: number, w1: number): number =>
  w0 + ((t - t0) * (w1 - w0)) / (t1 - t0)

export const spring = (x: number, hz = 2.8, z = 0.42): number => {
  if (x <= 0) return 0
  const w = 2 * Math.PI * hz
  const wd = w * Math.sqrt(1 - z * z)
  return (
    1 - Math.exp(-z * w * x) * (Math.cos(wd * x) + (z / Math.sqrt(1 - z * z)) * Math.sin(wd * x))
  )
}

export function phoneFlight(phoneTransform: string, held: boolean, t: number): PhoneFlight {
  const m = PHONE_TRANSFORM.exec(phoneTransform)
  const [x, y, rot, k] = [1, 2, 3, 4].map((i) => Number(m?.[i]))
  if (t < WIND[0]) return { x: x!, y: y!, rot: rot!, k: k!, held }
  if (t < WIND[1]) {
    const e = Math.max(0, Math.min(1, (98 - rot!) / (98 - 45)))
    return { x: x!, y: y!, rot: 98 - (98 - WIND_ROT) * e, k: k!, held: true }
  }
  const u = (t - FLING[0]) / (FLING[1] - FLING[0])
  const v = u * (1.35 - 0.35 * u)
  const [ax, ay] = throwArc(v)
  const dt = Math.max(0, t - RELEASE)
  return {
    x: ax,
    y: ay + DROP[0] * dt + DROP[1] * dt * dt,
    rot: WIND_ROT + spun(t),
    k: 1.15,
    held: t < RELEASE
  }
}

export function followThrough(tipAtRelease: Point, rise: number, t: number): Point {
  const T0 = tipAtRelease
  const SW: Point = [SWING[0], SWING[1] - rise]
  const OV: Point = [OVER[0], OVER[1] - rise]
  const SE: Point = [SETTLE[0], SETTLE[1] - rise]
  if (t < RELEASE + 0.32) {
    const u = 1 - (1 - (t - RELEASE) / 0.32) ** 3
    const at = (k: 0 | 1): number => (1 - u) ** 2 * T0[k] + 2 * u * (1 - u) * SW[k] + u * u * OV[k]
    return [at(0), at(1)]
  }
  const u = s01((t - RELEASE - 0.32) / 0.23)
  return [OV[0] + (SE[0] - OV[0]) * u, OV[1] + (SE[1] - OV[1]) * u]
}

function throwArc(v: number): Point {
  const at = (k: 0 | 1): number =>
    (1 - v) ** 2 * THROW[0][k] + 2 * v * (1 - v) * THROW[1][k] + v * v * THROW[2][k]
  return [at(0), at(1)]
}

function spun(t: number): number {
  const x = t - (RELEASE - 0.06)
  const d = 0.12
  if (x <= 0) return 0
  return x < d ? (SPIN * x * x) / (2 * d) : SPIN * (x - d / 2)
}
