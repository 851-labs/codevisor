import { bump, clamp, s01, TAU } from "../geometry/math.js"
import { botMascotMoods } from "../moods/moods.js"
import { hold, lidAt } from "../moods/timing.js"
import type { BotMascotPose } from "../pose.js"
import { warp } from "./calling-flight.js"

export const PICK_UP = 1.56
export const TALK_LOOP = 6.4
export const HANG_UP = 2.3
export const LET_GO = 1.35

interface Motion {
  readonly nod: number
  readonly tilt: number
  readonly turn: number
  readonly up: number
  readonly blink: number
  readonly bob: number
}

const TALK_FROM = warp(PICK_UP)
const BREATH = 1.6
const AT_EAR = 0.95
const AT_LOW = 0.4
const LOWER = [0.45, 1.25] as const
const settled = botMascotMoods.calling.pose(TALK_FROM)

const talkTurn = hold(
  [
    [0, 0],
    [3.3, -0.2],
    [4.9, 0]
  ],
  0.35
)
const talkUp = hold(
  [
    [0, 0],
    [3.3, 0.12],
    [4.9, 0]
  ],
  0.35
)

export function talkingPose(t: number): BotMascotPose {
  const nod = [0.35, 0.7, 3.9, 4.25].reduce((s, k) => s + bump((t - k) / 0.32), 0)
  const speaking = bump((t - 1.4) / 1.6)
  const syllables = speaking * Math.abs(Math.sin(TAU * 2.4 * (t - 1.4)))
  return onTheLine(
    t,
    {
      nod,
      tilt: -2 * speaking,
      turn: talkTurn(t),
      up: talkUp(t) - 0.05 * speaking,
      blink: lidAt(t, 0.16, 1.15, 3.45, 5.7),
      bob: 1.5 * syllables
    },
    TALK_FROM
  )
}

export function hangUpPose(t: number): BotMascotPose {
  const down = s01((t - LOWER[0]) / (LOWER[1] - LOWER[0]))
  const glance = bump((t - LOWER[0]) / 1.3)
  return onTheLine(
    t,
    {
      nod: bump((t - 0.05) / 0.36),
      tilt: -6 * down,
      turn: 0.15 * down,
      up: 0.22 * down + 0.3 * glance,
      blink: lidAt(t, 0.2, 1.9),
      bob: 0
    },
    phoneWhileHangingUp(t)
  )
}

export const hangUpSettle = (t: number): number => s01((t - 0.9) / 1.3)

function phoneWhileHangingUp(t: number): number {
  if (t < LOWER[0]) return TALK_FROM
  return AT_EAR - (AT_EAR - AT_LOW) * clamp((t - LOWER[0]) / (LOWER[1] - LOWER[0]), 0, 1)
}

function onTheLine(t: number, m: Motion, phone: number): BotMascotPose {
  const face = settled.face ?? {}
  return {
    ...settled,
    y: (settled.y ?? 0) - 3 * m.nod - m.bob,
    sy: 1 + 0.012 * Math.sin((TAU * (TALK_FROM + t)) / BREATH) - 0.04 * m.nod + 0.01 * m.bob,
    tilt: (settled.tilt ?? 0) + m.tilt + 3 * m.nod,
    face: {
      ...face,
      turn: (face.turn ?? 0) + m.turn,
      up: (face.up ?? 0) + m.up + 0.06 * m.nod,
      blink: m.blink
    },
    fx: [{ kind: "calling", t: phone, op: 1 }]
  }
}
