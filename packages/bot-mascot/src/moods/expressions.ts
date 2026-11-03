import { TAU } from "../geometry/math.js"
import type { BotMascotPose } from "../pose.js"
import { bake, blinkAt, hold } from "./timing.js"

export const IDLE_LOOP = 10

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
