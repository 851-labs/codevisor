import { clamp, s01, TAU } from "../geometry/math.js"
import type { BotMascotPose, Effect, LegPose } from "../pose.js"
import { accent, arcHeight, bake, blinkAt, decay, hold, lidAt } from "./timing.js"

export const IDLE_LOOP = 10
export const HAPPY_LOOP = 3.2
export const SAD_LOOP = 6
export const SLEEPY_LOOP = 6
export const SURPRISED_LOOP = 4.5

const gaze = hold([
  [0, 0],
  [2.2, -0.9],
  [3.4, 0.85],
  [4.6, 0],
  [8.3, 0.35],
  [9.1, 0]
])
const glance = hold([
  [0, 0],
  [6.6, -0.5],
  [7.4, 0]
])
const idleTurn = bake(gaze, 3.2, 0.8, IDLE_LOOP)
const idleUp = bake(glance, 2.8, 0.8, IDLE_LOOP)
const idleTilt = bake((t) => 4.5 * gaze(t - 0.06), 1.25, 0.42, IDLE_LOOP)
const idleTwist = bake((t) => 0.1 * gaze(t - 0.04), 1.6, 0.5, IDLE_LOOP)
const idleReach = bake((t) => -0.024 * glance(t), 2.2, 0.55, IDLE_LOOP)

const happyLook = hold([
  [0, 0],
  [0.3, 0.25],
  [1.7, -0.3],
  [2.6, 0]
])
const happyTurn = bake(happyLook, 3, 0.75, HAPPY_LOOP)
const happyUp = bake(
  hold(
    [
      [0, 0],
      [0.35, -0.4],
      [1.5, 0]
    ],
    0.25
  ),
  3,
  0.75,
  HAPPY_LOOP
)
const happyTilt = bake((t) => 4 * happyLook(t - 0.08), 1.4, 0.45, HAPPY_LOOP)

const sadLook = hold(
  [
    [0, 0],
    [2.3, -0.35],
    [4.1, 0.2],
    [5.4, 0]
  ],
  0.6
)
const sigh = hold(
  [
    [0, 0],
    [0.5, 0.03],
    [1.3, -0.035],
    [3.4, 0]
  ],
  0.6
)
const sadTurn = bake(sadLook, 1.6, 0.85, SAD_LOOP)
const sadUp = bake(
  hold(
    [
      [0, 0.5],
      [2.3, 0.75],
      [4.1, 0.6],
      [5.4, 0.5]
    ],
    0.6
  ),
  1.6,
  0.85,
  SAD_LOOP
)
const sadSigh = bake(sigh, 1.1, 0.7, SAD_LOOP)
const sadTilt = bake(
  (t) => 4 + 60 * -Math.min(0, sigh(t)) + 6 * sadLook(t - 0.15),
  0.9,
  0.6,
  SAD_LOOP
)
const TEAR = { form: 2.75, fall: 3.1, gone: 4.5 }

const sleepyDroop = hold(
  [
    [0, 3],
    [3.3, 8],
    [3.75, 11],
    [3.95, -2],
    [4.5, 1],
    [5.4, 3]
  ],
  0.3
)
const sleepyTilt = bake(sleepyDroop, 1.3, 0.5, SLEEPY_LOOP)
const sleepySquash = bake(
  hold(
    [
      [0, 0],
      [3.3, -0.03],
      [3.95, 0.025],
      [4.6, 0],
      [5.6, 0]
    ],
    0.3
  ),
  1.6,
  0.55,
  SLEEPY_LOOP
)

const surprisedLook = hold(
  [
    [0, 0],
    [1.05, -0.8],
    [1.75, 0.75],
    [2.45, 0]
  ],
  0.12
)
const startle = hold(
  [
    [0, 0],
    [0.02, 1],
    [0.2, -1],
    [0.9, 0]
  ],
  0.1
)
const surprisedWide = bake(
  hold(
    [
      [0, 1.07],
      [0.02, 0.9],
      [0.2, 1.24],
      [2.8, 1.18],
      [3.3, 1.07]
    ],
    0.08
  ),
  4.2,
  0.4,
  SURPRISED_LOOP
)
const surprisedTurn = bake(surprisedLook, 4, 0.7, SURPRISED_LOOP)
const surprisedTilt = bake(
  (t) => -3 * startle(t) + 4 * surprisedLook(t - 0.1),
  1.6,
  0.5,
  SURPRISED_LOOP
)

const HAPPY_SPARKLES: ReadonlyArray<readonly [number, number, number]> = [
  [-112, -10, 15],
  [104, -40, 13],
  [118, 34, 9],
  [-96, -46, 10]
]

export function idlePose(t: number): BotMascotPose {
  return {
    sy: 1 + 0.013 * Math.sin((TAU * t) / 1.25) + idleReach(t),
    lean: 0.6 * Math.sin((TAU * t) / IDLE_LOOP),
    tilt: idleTilt(t),
    twist: idleTwist(t),
    face: {
      turn: idleTurn(t),
      up: idleUp(t),
      blink: blinkAt(t, 1.4, 2.12, 3.32, 5.6, 5.84, 8.25),
      mode: "open"
    }
  }
}

export function happyPose(t: number): BotMascotPose {
  const antic = s01((t - 0.5) / 0.28) * (1 - s01((t - 0.76) / 0.07))
  const air = arcHeight(t, 0.78, 1.28, 38)
  const tuck = Math.sin(Math.PI * clamp((t - 0.82) / 0.42, 0, 1))
  const stretch = t > 0.78 && t < 1.2 ? 0.1 * Math.sin(Math.PI * clamp((t - 0.78) / 0.42, 0, 1)) : 0
  const land = -0.15 * decay(t, 1.28, 6, 2.6) * s01((t - 1.27) / 0.05)
  const bounce = 0.018 * Math.sin((TAU * t) / 0.8)
  const sy = 1 + bounce - 0.13 * antic + stretch + land
  const squat = Math.max(0, -land / 0.15)
  const legs: LegPose = { bend: 0.55 * antic + 0.6 * tuck + 0.35 * squat, lift: 6 * tuck }
  const eye = accent(t, 0.92, 1.5, "happy", 0.08, 0.12)
  const blink = Math.min(eye.blink, blinkAt(t, 2.55))
  const fx = HAPPY_SPARKLES.map(([dx, dy, r], i): Effect => {
    const a = 0.92 + i * 0.06
    const k = s01((t - a) / 0.12) * (1 - s01((t - 1.6 - i * 0.08) / 0.35))
    return { kind: "sparkle", x: 250 + dx, y: dy - 10 * k, r: r * (0.4 + 0.75 * k), op: k }
  })
  return {
    y: air,
    sy,
    lean: 3 * Math.sin((TAU * t) / 1.6),
    tilt: happyTilt(t),
    L: legs,
    R: legs,
    face: {
      turn: happyTurn(t),
      up: happyUp(t),
      mode: eye.mode,
      blink,
      cheeks: eye.mode === "happy" ? 1.18 : 1.05
    },
    fx
  }
}

export function sadPose(t: number): BotMascotPose {
  const eyeX = 250 + 34 * sadTurn(TEAR.form) + 26
  const formed = s01((t - TEAR.form) / 0.35)
  const fall = clamp((t - TEAR.fall) / (TEAR.gone - TEAR.fall - 0.3), 0, 1)
  const tear: Effect = {
    kind: "tear",
    x: eyeX,
    y: 300 + 58 * fall * fall,
    op: formed * (1 - s01((t - TEAR.gone + 0.35) / 0.35))
  }
  return {
    sy: 0.965 + 0.012 * Math.sin((TAU * t) / 3) + sadSigh(t),
    tilt: sadTilt(t),
    lean: 1 + 0.8 * Math.sin((TAU * t) / SAD_LOOP),
    face: {
      turn: sadTurn(t),
      up: sadUp(t),
      blink: Math.min(0.66, lidAt(t, 0.34, 1.45, 4.55)),
      brow: -18,
      cheekOp: 0.45
    },
    fx: tear.op > 0.01 ? [tear] : []
  }
}

export function sleepyPose(t: number): BotMascotPose {
  const awake = t >= 3.85 && t < 5.3
  const groggy = awake
    ? Math.min(0.08 + 0.5 * s01((t - 3.85) / 0.18), 0.58 - 0.12 * s01((t - 4.1) / 0.6))
    : 1
  const lid = awake ? Math.min(groggy, lidAt(t, 0.42, 4.55), 0.08 + 0.9 * s01((5.3 - t) / 0.35)) : 1
  const dozing = 1 - s01((t - 3.7) / 0.2) + s01((t - 5.35) / 0.4)
  const zs = [0, 1, 2].map((i): Effect => {
    const u = (t / 3 + i / 3) % 1
    return {
      kind: "z",
      x: 334 + 54 * u,
      y: 182 - 100 * u,
      s: 0.6 + 0.6 * u,
      op: Math.sin(Math.PI * u) * clamp(dozing, 0, 1)
    }
  })
  return {
    sy: 0.985 + 0.03 * Math.sin((TAU * t) / 3) + sleepySquash(t),
    lean: 1.5 * Math.sin((TAU * t) / 3),
    tilt: sleepyTilt(t),
    face: { mode: awake ? "open" : "sleepy", blink: awake ? lid : 1, up: awake ? 0.25 : 0 },
    fx: zs.filter((z) => z.op > 0.01)
  }
}

export function surprisedPose(t: number): BotMascotPose {
  const jump = arcHeight(t, 0.2, 0.58, 26)
  const antic = t < 0.2 ? Math.sin(Math.PI * (t / 0.2)) : 0
  const leap = t > 0.2 && t < 0.58 ? 0.1 * Math.sin((Math.PI * (t - 0.2)) / 0.38) : 0
  const sy =
    1 +
    0.012 * Math.sin((TAU * t) / 1.5) -
    0.06 * antic +
    leap -
    0.1 * decay(t, 0.58, 7, 2.5) * (t > 0.58 ? 1 : 0)
  const shiver = t > 0.58 && t < 1.05 ? 1.6 * Math.sin(TAU * 11 * t) * (1 - (t - 0.58) / 0.47) : 0
  const pop = s01((t - 0.22) / 0.1) * (1 - s01((t - 1.25) / 0.3))
  const blink = Math.min(0.08 + 0.92 * (1 - 0.35 * antic), blinkAt(t, 2.62, 2.84, 3.95))
  return {
    y: jump,
    sy,
    lean: shiver,
    tilt: surprisedTilt(t),
    face: { wide: surprisedWide(t), turn: surprisedTurn(t), blink, mode: "open" },
    fx: pop > 0.01 ? shockMarks(pop) : []
  }
}

function shockMarks(pop: number): ReadonlyArray<Effect> {
  const k = 0.5 + 0.5 * pop
  return [
    { kind: "pop", x: 352, y: 168, dx: 9 * k, dy: -22 * k, op: pop },
    { kind: "pop", x: 372, y: 196, dx: 22 * k, dy: -9 * k, op: pop }
  ]
}
