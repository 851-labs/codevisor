import { lerp, s01, smootherstep, type Point } from "../geometry/math.js"
import type { PlacedProp } from "./matrix.js"

export type PhoneHold = "reach" | "held" | "release"

export interface PhoneScene {
  readonly q: PlacedProp
  readonly hold: PhoneHold
  readonly arm: number
  readonly hand: number
}

type Span = readonly [number, number]

export const GROUND: PlacedProp = { x: 404, y: 398, rot: -70, k: 1.15 }
export const EAR: PlacedProp = { x: 303.98, y: 305.06, rot: 40, k: 1.15 }

const LIFT_VIA: Point = [398, 318]
const POP = 0.12

const PICK = {
  appear: [0, 0.16],
  reach: [0.06, 0.4],
  close: [0.4, 0.46],
  lift: [0.46, 0.9]
} as const satisfies Record<string, Span>

const DROP = {
  lower: [0.3, 0.78],
  open: [0.78, 0.84],
  retract: [0.82, 1.14],
  vanish: [1.14, 1.34]
} as const satisfies Record<string, Span>

export const PICK_UP = 1.56
export const PICKED_UP = PICK.lift[1]
export const LIFT_FROM = PICK.lift[0]

export function pickUpScene(t: number): PhoneScene {
  if (t < PICK.close[0]) {
    const q = { ...GROUND, k: GROUND.k * popIn(within(t, PICK.appear)) }
    return { q, hold: "reach", arm: smootherstep(within(t, PICK.reach)), hand: 0 }
  }
  const q = carried(smootherstep(within(t, PICK.lift)))
  return { q, hold: "held", arm: 1, hand: s01(within(t, PICK.close)) }
}

export function hangUpScene(t: number): PhoneScene {
  if (t < DROP.open[0]) {
    return { q: carried(1 - smootherstep(within(t, DROP.lower))), hold: "held", arm: 1, hand: 1 }
  }
  const q = { ...GROUND, k: GROUND.k * (1 - smootherstep(within(t, DROP.vanish))) }
  const arm = 1 - smootherstep(within(t, DROP.retract))
  return { q, hold: "release", arm, hand: 1 - s01(within(t, DROP.open)) }
}

export const HUNG_UP = DROP.vanish[1]

const within = (t: number, [from, to]: Span): number =>
  Math.max(0, Math.min(1, (t - from) / (to - from)))

const popIn = (x: number): number => s01(x) * (1 + POP * Math.sin(Math.PI * x))

function carried(u: number): PlacedProp {
  const v = 1 - u
  const at = (k: 0 | 1, a: number, b: number): number =>
    v * v * a + 2 * u * v * LIFT_VIA[k] + u * u * b
  return {
    x: at(0, GROUND.x, EAR.x),
    y: at(1, GROUND.y, EAR.y),
    rot: lerp(GROUND.rot, EAR.rot, u),
    k: EAR.k
  }
}
