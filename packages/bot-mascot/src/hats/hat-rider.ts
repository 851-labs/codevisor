import type { Body } from "../body/zones.js"
import { anchorAt, toWorld } from "../drapes/anchors.js"
import { clamp, TAU, type Point } from "../geometry/math.js"
import type { BotMascotPose } from "../pose.js"

export interface HatMotion {
  readonly rot: number
  readonly dy: number
  readonly spin: number
  readonly impact: number
  readonly falling: boolean
  readonly tipX: number
  readonly tipY: number
}

export interface HatRider {
  readonly reset: () => void
  readonly drop: (height?: number) => void
  readonly step: (body: Body, pose: BotMascotPose, dt: number) => HatMotion
}

interface Tip {
  p: [number, number]
  v: [number, number]
  T: Point
}

interface RiderState {
  th: number
  top: number
  ang: number
  av: number
  y: number
  v: number
  falling: boolean
  bounces: number
  spin: number
  sv: number
  impact: number
  tip: Tip | null
}

const WA = TAU * 2.4
const ZA = 0.3
const WY = TAU * 5.5
const ZY = 0.5
const GRAVITY = 3200
const SUBSTEP = 1 / 240
const TIP_STIFFNESS = [(TAU * 1.25) ** 2, (TAU * 2.8) ** 2] as const
const TIP_DAMPING = [2 * 0.15 * TAU * 1.25, 2 * 0.34 * TAU * 2.8] as const
const STALK = 60
const MAX_TIP = 46

export function hatRider(): HatRider {
  let s: RiderState | null = null
  let pending = 0
  const drop = (height = 260): void => {
    if (s)
      Object.assign(s, {
        y: s.top - height,
        v: 0,
        falling: true,
        bounces: 0,
        ang: s.th + 9,
        av: 0,
        tip: null
      })
    else pending = height
  }
  return {
    reset: () => {
      s = null
      pending = 0
    },
    drop,
    step: (body, pose, dtIn) => {
      const th = (pose.tilt || 0) + (pose.lean || 0) + (pose.spin || 0)
      const top = -(pose.y || 0) - (226 + (body.zoned ? body.rise : 0)) * (pose.sy ?? 1)
      if (!s) {
        s = freshState(th, top)
        if (pending) {
          drop(pending)
          pending = 0
        }
      }
      const dt = Math.min(Math.max(dtIn, 0), 0.05)
      const n = Math.max(1, Math.ceil(dt / SUBSTEP))
      const thv = dt ? (th - s.th) / dt : 0
      const topv = dt ? (top - s.top) / dt : 0
      settleOnHead(s, th, top, topv, n, dt / n)
      s.th = th
      s.top = top
      s.impact *= Math.exp(-dt * 7)
      spinPropeller(s, topv, thv, dt)
      const { tipX, tipY } = swingTip(s, body, pose, th, n, dt)
      return {
        rot: clamp(s.ang - th, -16, 16),
        dy: Math.min(0, s.y - top),
        spin: s.spin,
        impact: s.impact,
        falling: s.falling,
        tipX,
        tipY
      }
    }
  }
}

function freshState(th: number, top: number): RiderState {
  return {
    th,
    top,
    ang: th,
    av: 0,
    y: top,
    v: 0,
    falling: false,
    bounces: 0,
    spin: 0.6,
    sv: TAU * 0.55,
    impact: 0,
    tip: null
  }
}

function settleOnHead(
  s: RiderState,
  th: number,
  top: number,
  topv: number,
  n: number,
  h: number
): void {
  for (let i = 1; i <= n; i++) {
    const T = s.th + ((th - s.th) * i) / n
    const Y = s.top + ((top - s.top) * i) / n
    s.av += h * (WA * WA * (T - s.ang) - 2 * ZA * WA * s.av)
    s.ang += h * s.av
    s.v += s.falling ? h * GRAVITY : h * (WY * WY * (Y - s.y) - 2 * ZY * WY * (s.v - topv))
    s.y += h * s.v
    if (s.y > Y) land(s, Y, topv)
  }
}

function land(s: RiderState, Y: number, topv: number): void {
  const rel = s.v - topv
  s.y = Y
  if (s.falling && rel > 260) {
    s.v = topv - 0.3 * rel
    s.impact = Math.max(s.impact, Math.min(1, rel / 1100))
    if (++s.bounces >= 2) s.falling = false
  } else {
    s.falling = false
    s.v = topv
  }
}

function spinPropeller(s: RiderState, topv: number, thv: number, dt: number): void {
  const want = TAU * (0.55 + Math.min(3, Math.abs(topv) / 120 + Math.abs(thv) / 40))
  s.sv += (want - s.sv) * Math.min(1, dt * 3)
  s.spin = (s.spin + s.sv * dt) % TAU
}

function swingTip(
  s: RiderState,
  body: Body,
  pose: BotMascotPose,
  th: number,
  n: number,
  dt: number
): { tipX: number; tipY: number } {
  const h = dt / n
  const thr = (th * Math.PI) / 180
  const B = toWorld(pose, anchorAt(body, pose, [250, 186]))
  const T: Point = [B[0] + Math.sin(thr) * STALK, B[1] - Math.cos(thr) * STALK]
  s.tip ??= { p: [T[0], T[1]], v: [0, 0], T: [T[0], T[1]] }
  const tip = s.tip
  const tv: Point = dt ? [(T[0] - tip.T[0]) / dt, (T[1] - tip.T[1]) / dt] : [0, 0]
  for (let i = 1; i <= n; i++) {
    const tx = tip.T[0] + ((T[0] - tip.T[0]) * i) / n
    const ty = tip.T[1] + ((T[1] - tip.T[1]) * i) / n
    for (const k of [0, 1] as const) {
      const goal = k ? ty : tx
      tip.v[k] += h * (TIP_STIFFNESS[k] * (goal - tip.p[k]) - TIP_DAMPING[k] * (tip.v[k] - tv[k]))
      tip.p[k] += h * tip.v[k]
    }
  }
  tip.T = T
  let ox = tip.p[0] - T[0]
  let oy = tip.p[1] - T[1]
  const m = Math.hypot(ox, oy)
  if (m > MAX_TIP) {
    ox *= MAX_TIP / m
    oy *= MAX_TIP / m
  }
  return {
    tipX: ox * Math.cos(thr) + oy * Math.sin(thr),
    tipY: -ox * Math.sin(thr) + oy * Math.cos(thr)
  }
}
