import type { Body } from "../body/zones.js"
import { EYE_Y } from "../face/eye-shape.js"
import { clamp, lerp, type Point } from "../geometry/math.js"
import type { BotMascotPose } from "../pose.js"

export interface BotMascotGaze {
  readonly x: number
  readonly y: number
  readonly weight?: number
}

export interface GazeRange {
  readonly turn: number
  readonly up: number
  readonly down: number
  readonly reachX: number
  readonly reachY: number
}

export const GAZE_RANGE: GazeRange = { turn: 0.8, up: 0.55, down: 0.45, reachX: 170, reachY: 150 }

const TILT_PER_TURN = 4.5
const TWIST_PER_TURN = 0.1
const STRETCH_PER_UP = 0.024

interface Look {
  readonly turn: number
  readonly up: number
}

export const gazeOrigin = (body: Body): Point => [250, EYE_Y - body.rise]

export function lookingAt(
  pose: BotMascotPose,
  gaze: BotMascotGaze | null | undefined,
  origin: Point
): BotMascotPose {
  const w = clamp(gaze?.weight ?? 1, 0, 1)
  if (!gaze || w <= 0) return pose

  const look = lookToward(gaze, origin)
  const face = pose.face ?? {}
  return {
    ...pose,
    sy: (pose.sy ?? 1) - STRETCH_PER_UP * w * (look.up - (face.up ?? 0)),
    tilt: lerp(pose.tilt ?? 0, TILT_PER_TURN * look.turn, w),
    twist: lerp(pose.twist ?? 0, TWIST_PER_TURN * look.turn, w),
    face: { ...face, turn: lerp(face.turn ?? 0, look.turn, w), up: lerp(face.up ?? 0, look.up, w) }
  }
}

function lookToward(gaze: BotMascotGaze, origin: Point): Look {
  const r = GAZE_RANGE
  const dx = Math.tanh((gaze.x - origin[0]) / r.reachX)
  const dy = Math.tanh((gaze.y - origin[1]) / r.reachY)
  return { turn: r.turn * dx, up: dy < 0 ? r.up * dy : r.down * dy }
}
