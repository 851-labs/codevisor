import { lerp, RAD, s01, wrapDegrees, type Point } from "../geometry/math.js"
import { outlinePoly, signedDistance } from "./outline-poly.js"
import { armOrigin, RIG_CURVE, type RigArm, type Torso } from "./rig-arm.js"

export interface CurlByDistance {
  (d: number): number
  readonly even: number
}

export interface ReachOptions {
  readonly curl?: number | undefined
  readonly from?: Point
  readonly upCurl?: CurlByDistance
}

type Profile = (u: number) => number

const UP = -45
const CURL_MAX = 90
const DOWN_OUT = 30
const DOWN_IN = 50
const UP_CURL = 15
const SCOOP = 40
const ACROSS = 70
const STEPS = 120

export const upCurl = (): number => -UP_CURL

export function bendOf(torso: Torso, side: number, O0: Point, T: Point): CurlByDistance {
  const across = s01((-side * (T[0] - O0[0]) - 20) / 40)
  const below = s01((T[1] - O0[1] + 16) / 32)
  const up = Math.atan2(O0[1] - T[1], Math.abs(T[0] - O0[0])) / RAD
  const sd = signedDistance(outlinePoly(torso.d), T).d
  const wOut = s01((sd + 10) / 20)
  const onHim = (1 - s01((sd - 15) / 25)) * s01((up - 25) / 30)
  const f = (): number => {
    const flip = wOut * upCurl()
    return flip + below * across * (SCOOP - flip) + (1 - below) * onHim * (ACROSS - flip)
  }
  return Object.assign(f, { even: (1 - below) * onHim })
}

export function reach(torso: Torso, side: number, target: Point, opts: ReachOptions = {}): RigArm {
  const { curl, from, upCurl: curlFor } = opts
  const ev = curlFor?.even || 0
  const p: Profile = ev > 0 ? (u) => lerp(RIG_CURVE(u), u, ev) : RIG_CURVE
  const O0 = from || armOrigin(torso, side)
  const aim = new Aim(side, O0, target)
  let c = curlOf(curl, curlFor, aim.distance)
  let th = aim.angle - (side * c) / 2
  let L = aim.distance
  ;[th, L] = aim.solve((x, y) => aim.end(x, c, y, p), th, L, 1)
  let q = p
  const wOutside = s01((signedDistance(outlinePoly(torso.d), target).d - 15) / 25)
  if (curl == null && wOutside > 0 && aim.relative(th) < UP && aim.relative(th) > -180 + 1e-9) {
    ;({ th, c, L, q } = arcUp(aim, th, c, p, wOutside))
  }
  if (curl == null) ({ th, c, L, q } = leaveDownward(aim, th, c, L, q))
  const cFinal = c
  const qFinal = q
  return { R: O0, th, L, turn: (u) => side * cFinal * qFinal(u), c }
}

interface Solved {
  readonly th: number
  readonly c: number
  readonly L: number
  readonly q: Profile
}

function curlOf(
  curl: number | undefined,
  curlFor: CurlByDistance | undefined,
  distance: number
): number {
  if (curl != null) return curl
  return curlFor ? curlFor(distance) : 0
}

function arcUp(aim: Aim, th0: number, c0: number, p: Profile, wOutside: number): Solved {
  const phi = aim.relative(aim.angle)
  const wAc = s01((Math.abs(phi) - 120) / 30)
  const thT = lerp(Math.min(UP, Math.max(UP - 10, phi + CURL_MAX / 2)), aim.relative(th0), wAc)
  let th = aim.absolute(thT)
  let q: Profile = (u) => lerp(u, p(u), wAc)
  let { c, L } = aim.arcTo(th, 10)
  ;[c, L] = aim.solve((x, y) => aim.end(th, x, y, q), c, L, 4)
  if (wOutside >= 1) return { th, c, L, q }

  th = th0 + wrapDegrees(th - th0) * wOutside
  c = lerp(c0, c, wOutside)
  const qO = q
  q = (u) => lerp(p(u), qO(u), wOutside)
  const cFixed = c
  const qFixed = q
  ;[th, L] = aim.solve((x, y) => aim.end(x, cFixed, y, qFixed), th, L, 1)
  return { th, c, L, q }
}

function leaveDownward(aim: Aim, th0: number, c0: number, L0: number, q0: Profile): Solved {
  const phi = aim.relative(aim.angle)
  const t0 = aim.relative(th0)
  const unchanged = { th: th0, c: c0, L: L0, q: q0 }
  if (!(phi > 20 && t0 > 90 - DOWN_OUT - 30 && t0 < 90 + DOWN_IN + 30)) return unchanged
  const tOut = Math.min(t0, 90 - DOWN_OUT)
  const tIn = Math.max(t0, 90 + DOWN_IN)
  const thT = lerp(tOut, tIn, s01((phi - 94) / 4))
  const dth = thT - t0
  if (Math.abs(dth) <= 0.01) return unchanged
  const th = aim.absolute(thT)
  const ev = s01(Math.abs(dth) / 10)
  const q: Profile = (u) => lerp(q0(u), u, ev)
  let { c, L } = aim.arcTo(th, 4)
  ;[c, L] = aim.solve((x, y) => aim.end(th, x, y, q), c, L, 4)
  return { th, c, L, q }
}

class Aim {
  readonly angle: number
  readonly distance: number

  constructor(
    readonly side: number,
    readonly O0: Point,
    readonly target: Point
  ) {
    this.angle = Math.atan2(target[1] - O0[1], target[0] - O0[0]) / RAD
    this.distance = Math.hypot(target[0] - O0[0], target[1] - O0[1])
  }

  relative(x: number): number {
    return wrapDegrees(this.side > 0 ? x : 180 - x)
  }

  absolute(v: number): number {
    return this.side > 0 ? v : 180 - v
  }

  end(th: number, c: number, L: number, q: Profile): Point {
    let x = this.O0[0]
    let y = this.O0[1]
    for (let i = 0; i < STEPS; i++) {
      const a = (th + this.side * c * q((i + 0.5) / STEPS)) * RAD
      x += (Math.cos(a) * L) / STEPS
      y += (Math.sin(a) * L) / STEPS
    }
    return [x, y]
  }

  arcTo(th: number, minL: number): { c: number; L: number } {
    const R0 = this.O0
    const ph = Math.atan2(this.target[1] - R0[1], this.target[0] - R0[0]) / RAD
    const dphi = wrapDegrees(ph - th)
    const hc = Math.abs(dphi) * RAD
    const chord = Math.hypot(this.target[0] - R0[0], this.target[1] - R0[1])
    return { c: this.side * 2 * dphi, L: Math.max(minL, (chord * (hc || 1)) / (Math.sin(hc) || 1)) }
  }

  solve(
    end: (x: number, L: number) => Point,
    x0: number,
    L0: number,
    minL: number
  ): readonly [number, number] {
    let x = x0
    let L = L0
    for (let it = 0; it < 60; it++) {
      const E = end(x, L)
      const r: Point = [E[0] - this.target[0], E[1] - this.target[1]]
      if (Math.hypot(...r) < 0.01) break
      const Ex = end(x + 0.3, L)
      const El = end(x, L + 0.3)
      const a = (Ex[0] - E[0]) / 0.3
      const b = (El[0] - E[0]) / 0.3
      const cc = (Ex[1] - E[1]) / 0.3
      const d = (El[1] - E[1]) / 0.3
      const det = a * d - b * cc
      if (Math.abs(det) < 1e-9) break
      const dx = (-r[0] * d + r[1] * b) / det
      const dL = (-a * r[1] + cc * r[0]) / det
      const sc = Math.min(1, 15 / Math.abs(dx || 1e-9), Math.max(15, L / 2) / Math.abs(dL || 1e-9))
      x += dx * sc
      L = Math.max(minL, L + dL * sc)
    }
    return [x, L]
  }
}
