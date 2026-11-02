import { bump, lerp, s01, TAU, type Point } from "../geometry/math.js"

export type PhonePlace = readonly [number, number, number]

export interface PhoneState {
  readonly x: number
  readonly y: number
  readonly rot: number
  readonly s: number
  readonly ring: number | null
  readonly held: boolean
}

export interface FollowHand {
  readonly x: number
  readonly y: number
  readonly rot: number
  readonly s: number
  readonly ring: number
}

export const CALL = {
  pop: 0.3,
  lift: [0.4, 0.95],
  annoy: 2.3,
  mad: 4.0,
  pull: [5.0, 5.35],
  wind: [6.5, 6.95],
  fling: [6.95, 7.35],
  huff: 7.45,
  calm: 8.05
} as const

const MOUTH: Point = [266.2, 330.4]
const MOUTHPIECE: Point = [-11 * 1.15, 38 * 1.15]
const LOW: PhonePlace = [320, 374, 18]
const WIND: PhonePlace = [382, 248, 45]
const GONE: PhonePlace = [-160, 170, 45 - 900]
const VIA: Point = [250, 535]

export const aboutMouthpiece = (rot: number): PhonePlace => {
  const a = (rot * Math.PI) / 180
  const c = Math.cos(a)
  const s = Math.sin(a)
  return [
    MOUTH[0] - (MOUTHPIECE[0] * c - MOUTHPIECE[1] * s),
    MOUTH[1] - (MOUTHPIECE[0] * s + MOUTHPIECE[1] * c),
    rot
  ]
}

const EAR = aboutMouthpiece(40)
const YELL = aboutMouthpiece(98)

const lerp3 = (a: PhonePlace, b: PhonePlace, u: number): [number, number, number] => [
  lerp(a[0], b[0], u),
  lerp(a[1], b[1], u),
  lerp(a[2], b[2], u)
]

export const throwArc = (v: number): Point => [
  (1 - v) ** 2 * WIND[0] + 2 * v * (1 - v) * VIA[0] + v * v * GONE[0],
  (1 - v) ** 2 * WIND[1] + 2 * v * (1 - v) * VIA[1] + v * v * GONE[1]
]

export const annoyance = (t: number): number =>
  s01((t - CALL.annoy) / 1.5) * (1 - s01((t - CALL.calm) / 0.6))
export const rage = (t: number): number => s01((t - CALL.mad) / 0.5) * (1 - s01((t - 7.7) / 0.5))
export const yelling = (t: number): number =>
  s01((t - CALL.pull[1]) / 0.15) * (1 - s01((t - CALL.wind[0]) / 0.1))

export function phoneAt(t: number): PhoneState {
  const placed = phonePlace(t)
  const shake = t >= CALL.pull[1] && t < CALL.wind[0]
  const p = shake ? shaken(placed.p, t) : placed.p
  return {
    x: p[0],
    y: p[1],
    rot: p[2],
    s: Math.max(0, placed.s),
    ring: placed.ring,
    held: placed.held
  }
}

export function followHand(t: number): FollowHand | null {
  const release = CALL.fling[0] + 0.22 * (CALL.fling[1] - CALL.fling[0])
  if (t < release || t > 8.05) return null
  const { v, rot, s, ring } = followPath(t, release)
  const [x, y] = throwArc(v)
  const off = 20 - 10 * s01((t - release) / 0.3)
  return { x, y: y + off, rot, s: Math.max(0, s), ring }
}

interface Placed {
  readonly p: PhonePlace
  readonly s: number
  readonly ring: number | null
  readonly held: boolean
}

function phonePlace(t: number): Placed {
  if (t < CALL.pop) return popping(t / CALL.pop)
  if (t < CALL.lift[0]) return at(LOW)
  if (t < CALL.lift[1]) return at(lifting(t))
  if (t < CALL.pull[0]) return at(EAR)
  if (t < CALL.pull[1])
    return at(
      aboutMouthpiece(
        lerp(EAR[2], YELL[2], s01((t - CALL.pull[0]) / (CALL.pull[1] - CALL.pull[0])))
      )
    )
  if (t < CALL.wind[0]) return at(YELL)
  if (t < CALL.wind[1])
    return at(lerp3(YELL, WIND, s01((t - CALL.wind[0]) / (CALL.wind[1] - CALL.wind[0]))))
  if (t < CALL.fling[1]) return flung(t)
  return { p: LOW, s: 0, ring: null, held: false }
}

function at(p: PhonePlace): Placed {
  return { p, s: 1, ring: null, held: true }
}

function popping(u: number): Placed {
  return { p: LOW, s: s01(u / 0.7) * 1.2 - 0.2 * s01((u - 0.7) / 0.3), ring: u, held: true }
}

function lifting(t: number): PhonePlace {
  const u = s01((t - CALL.lift[0]) / (CALL.lift[1] - CALL.lift[0]))
  const p = lerp3(LOW, EAR, u)
  p[1] -= 12 * bump(u)
  return p
}

function flung(t: number): Placed {
  const u = (t - CALL.fling[0]) / (CALL.fling[1] - CALL.fling[0])
  const v = u * (1.35 - 0.35 * u)
  return {
    p: [...throwArc(v), WIND[2] + 45 * s01(v / 0.3) - 900 * v ** 4],
    s: 1,
    ring: null,
    held: u < 0.22
  }
}

function shaken(p: PhonePlace, t: number): PhonePlace {
  return [
    p[0] + 3 * Math.sin(TAU * 17 * t),
    p[1] + 2 * Math.sin(TAU * 13 * t + 1),
    p[2] + 4 * Math.sin(TAU * 11 * t)
  ]
}

interface FollowStep {
  readonly v: number
  readonly rot: number
  readonly s: number
  readonly ring: number
}

function followPath(t: number, rel: number): FollowStep {
  const v0 = 0.22 * (1.35 - 0.35 * 0.22)
  const vOver = 0.53
  const vRest = 0.47
  if (t < rel + 0.32) {
    const u = (t - rel) / 0.32
    const e = 1 - (1 - u) ** 3
    return {
      v: v0 + (vOver - v0) * e,
      rot: -78 - 26 * Math.sin(Math.PI * Math.min(1, u * 1.2)),
      s: 0.74,
      ring: 0
    }
  }
  if (t < rel + 0.55) {
    const u = s01((t - rel - 0.32) / 0.23)
    return { v: vOver + (vRest - vOver) * u, rot: -78 + 22 * u, s: 0.74, ring: 0 }
  }
  if (t < rel + 0.75)
    return { v: vRest, rot: -56 + 2 * Math.sin(TAU * 1.5 * (t - rel - 0.55)), s: 0.74, ring: 0 }
  const u = (t - rel - 0.75) / 0.22
  return {
    v: vRest,
    rot: -56,
    s: 0.74 * (1 + 0.1 * bump(Math.min(1, u / 0.3)) - s01((u - 0.2) / 0.8)),
    ring: (u - 0.2) / 0.9
  }
}
