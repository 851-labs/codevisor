import { s01, TAU, type Point } from "../geometry/math.js"
import { blendPoses } from "../moods/moods.js"
import type { BotMascotPose, SleepZEffect } from "../pose.js"

export const FALL_ASLEEP = 1.2
export const SLEEP_LOOP = 6.4
export const WAKE_UP = 0.7
export const SLEEP_Z_COUNT = 3

const BREATH = SLEEP_LOOP / 2
const Z_LIFE = SLEEP_LOOP / 2
const Z_START: Point = [388, 166]
const Z_RISE: Point = [62, -150]
const Z_SIZE = [18, 46] as const
const CLOSED = 0.08
const DROWSY = 0.45
export const Z_FADE_IN = 0.6
export const Z_FADE_OUT = 0.35

export function sleepPose(asleep: number, zs = 1): BotMascotPose {
  const breath = Math.sin((TAU * asleep) / BREATH)
  return {
    sy: 1 + 0.022 * breath,
    lean: 0.5 * Math.sin((TAU * asleep) / SLEEP_LOOP),
    tilt: 6 + 0.8 * breath,
    face: { turn: 0, up: 0.35, blink: CLOSED, mode: "open" },
    fx: sleepZs(asleep, zs)
  }
}

export function fallingAsleep(t: number, idle: BotMascotPose): BotMascotPose {
  const u = s01(t / FALL_ASLEEP)
  const asleep = blendPoses(idle, sleepPose(t - FALL_ASLEEP, zsArriving(t)), u)
  return { ...asleep, face: { ...asleep.face, blink: closingLid(t, idle.face?.blink ?? 1) } }
}

export function wakingUp(t: number, asleep: number, idle: BotMascotPose): BotMascotPose {
  const u = s01(t / WAKE_UP)
  const zs = 1 - s01(t / Z_FADE_OUT)
  const awake = blendPoses(sleepPose(asleep + t, zs), idle, u)
  const stretch = 0.03 * Math.sin(Math.PI * u)
  return {
    ...awake,
    sy: (awake.sy ?? 1) + stretch,
    face: { ...awake.face, blink: openingLid(t, idle.face?.blink ?? 1) },
    fx: sleepZs(asleep + t, zs)
  }
}

export function sleepZs(asleep: number, strength: number): ReadonlyArray<SleepZEffect> {
  if (strength <= 0) return []
  return Array.from({ length: SLEEP_Z_COUNT }, (_, i) => sleepZ(zProgress(asleep, i), i, strength))
}

export function zStroke(z: SleepZEffect): ReadonlyArray<Point> {
  const half = z.size / 2
  const turn = (z.rot * Math.PI) / 180
  const corner = ([x, y]: Point): Point => [
    z.x + x * Math.cos(turn) - y * Math.sin(turn),
    z.y + x * Math.sin(turn) + y * Math.cos(turn)
  ]
  return [
    corner([-half, -half]),
    corner([half, -half]),
    corner([-half, half]),
    corner([half, half])
  ]
}

const zProgress = (asleep: number, i: number): number => {
  const p = asleep / Z_LIFE - i / SLEEP_Z_COUNT
  return p - Math.floor(p)
}

function sleepZ(p: number, i: number, strength: number): SleepZEffect {
  const appear = s01(p / 0.18)
  const vanish = 1 - s01((p - 0.62) / 0.38)
  return {
    kind: "z",
    x: Z_START[0] + Z_RISE[0] * p + 6 * Math.sin(TAU * p + i),
    y: Z_START[1] + Z_RISE[1] * p,
    size: Z_SIZE[0] + (Z_SIZE[1] - Z_SIZE[0]) * p,
    rot: -14 + 12 * p,
    op: strength * appear * vanish
  }
}

const zsArriving = (t: number): number => s01((t - (FALL_ASLEEP - Z_FADE_IN)) / Z_FADE_IN)

function closingLid(t: number, open: number): number {
  const droop = open + (DROWSY - open) * s01(t / (0.35 * FALL_ASLEEP))
  const shut = s01((t - 0.55 * FALL_ASLEEP) / (0.4 * FALL_ASLEEP))
  return droop + (CLOSED - droop) * shut
}

function openingLid(t: number, open: number): number {
  const lift = s01(t / (0.45 * WAKE_UP))
  return CLOSED + (open - CLOSED) * lift
}
