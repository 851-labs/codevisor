import type { Body } from "../body/zones.js"
import { clamp, TAU, type Point } from "../geometry/math.js"
import type { Dangle } from "../outfits/outfits.js"
import type { BotMascotPose } from "../pose.js"
import { anchorAt, toLocal, toWorld } from "./anchors.js"

export interface DanglingEnd {
  readonly reset: () => void
  readonly step: (body: Body, pose: BotMascotPose, dt: number) => Point
}

interface Constants {
  readonly L: number
  readonly rest: number
  readonly gx: number
  readonly gy: number
  readonly gl: number
  readonly KL: number
  readonly CL: number
  readonly CS: number
}

interface Weight {
  K: Point
  p: [number, number]
  v: [number, number]
}

const SUBSTEP = 1 / 240
const MAX_SWING = 1.22

export function dangle(o: Dangle): DanglingEnd {
  const k = constantsOf(o)
  let s: Weight | null = null
  return {
    reset: () => {
      s = null
    },
    step: (body, pose, dtIn) => {
      const anchorPose = o.neck || o.waist ? { ...pose, neck: !!o.neck, waist: !!o.waist } : pose
      const K = toWorld(pose, anchorAt(body, anchorPose, o.anchor))
      s ??= { K, p: [K[0] + Math.sin(k.gl) * k.L, K[1] + Math.cos(k.gl) * k.L], v: [0, 0] }
      advance(s, k, K, clamp(dtIn, 0, 0.05))
      s.K = K
      return toLocal(pose, s.p)
    }
  }
}

function constantsOf(o: Dangle): Constants {
  const L = o.L
  const W = TAU * (o.swing || 2.4)
  const G = W * W * L
  const KL = (TAU * 4.2) ** 2
  const gl = ((o.lean || 0) * Math.PI) / 180
  return {
    L,
    rest: L - G / KL,
    gx: G * Math.sin(gl),
    gy: G * Math.cos(gl),
    gl,
    KL,
    CL: 2 * 0.12 * TAU * 4.2,
    CS: 2 * 0.1 * W
  }
}

function advance(s: Weight, k: Constants, K: Point, dt: number): void {
  const n = Math.max(1, Math.ceil(dt / SUBSTEP))
  const h = dt / n
  const kv: Point = dt ? [(K[0] - s.K[0]) / dt, (K[1] - s.K[1]) / dt] : [0, 0]
  for (let i = 1; i <= n; i++) {
    const kx = s.K[0] + ((K[0] - s.K[0]) * i) / n
    const ky = s.K[1] + ((K[1] - s.K[1]) * i) / n
    substep(s, k, kx, ky, kv, h)
  }
}

function substep(s: Weight, k: Constants, kx: number, ky: number, kv: Point, h: number): void {
  let dx = s.p[0] - kx
  let dy = s.p[1] - ky
  let len = Math.hypot(dx, dy) || 1e-6
  let ux = dx / len
  let uy = dy / len
  const rvx = s.v[0] - kv[0]
  const rvy = s.v[1] - kv[1]
  const along = rvx * ux + rvy * uy
  const f = -k.KL * (len - k.rest) - k.CL * along
  s.v[0] += h * (k.gx + f * ux - k.CS * rvx)
  s.v[1] += h * (k.gy + f * uy - k.CS * rvy)
  s.p[0] += h * s.v[0]
  s.p[1] += h * s.v[1]
  dx = s.p[0] - kx
  dy = s.p[1] - ky
  len = Math.hypot(dx, dy) || 1e-6
  ux = dx / len
  uy = dy / len
  const ang = Math.atan2(dx, dy)
  if (Math.abs(ang) > MAX_SWING) [ux, uy] = limitSwing(s, kx, ky, kv, len, ang)
  limitLength(s, k.L, kx, ky, kv, len, ux, uy)
}

function limitSwing(s: Weight, kx: number, ky: number, kv: Point, len: number, ang: number): Point {
  const a = Math.sign(ang) * MAX_SWING
  s.p = [kx + Math.sin(a) * len, ky + Math.cos(a) * len]
  const ux = Math.sin(a)
  const uy = Math.cos(a)
  const t = (s.v[0] - kv[0]) * uy - (s.v[1] - kv[1]) * ux
  if (t * Math.sign(ang) > 0) {
    s.v[0] -= t * uy * 1.5
    s.v[1] += t * ux * 1.5
  }
  return [ux, uy]
}

function limitLength(
  s: Weight,
  L: number,
  kx: number,
  ky: number,
  kv: Point,
  len: number,
  ux: number,
  uy: number
): void {
  const rel = (s.v[0] - kv[0]) * ux + (s.v[1] - kv[1]) * uy
  if (len > L * 1.06 && rel > 0) {
    s.p = [kx + ux * L * 1.06, ky + uy * L * 1.06]
    s.v[0] -= 1.95 * rel * ux
    s.v[1] -= 1.95 * rel * uy
  } else if (len < L * 0.4 && rel < 0) {
    s.p = [kx + ux * L * 0.4, ky + uy * L * 0.4]
    s.v[0] -= rel * ux
    s.v[1] -= rel * uy
  }
}
