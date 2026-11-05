import { s01 } from "../geometry/math.js"
import { blendPoses } from "../moods/moods.js"
import { blinkAt } from "../moods/timing.js"
import type { BotMascotPose } from "../pose.js"
import { hangUpScene, HUNG_UP, type PhoneScene } from "./calling-ground.js"
import { CALLING_SWAP_LOOP, callingSwapPose } from "./calling-swap.js"
import {
  HANG_UP,
  hangUpPose,
  hangUpSettle,
  PICK_UP,
  TALK_LOOP,
  talkingPose
} from "./calling-talk.js"

export type CallSegment = "pickUp" | "calling" | "hangUp" | "angryHangUp"
export type CallEnding = Extract<CallSegment, "hangUp" | "angryHangUp">

export interface CallShot {
  readonly t0: number
  readonly pose: BotMascotPose
  readonly exit?: number
  readonly phone?: PhoneScene
}

export const ANGRY_HANG_UP = CALLING_SWAP_LOOP - PICK_UP

export const callSeconds: Readonly<Record<CallSegment, number>> = {
  pickUp: PICK_UP,
  calling: TALK_LOOP,
  hangUp: HANG_UP,
  angryHangUp: ANGRY_HANG_UP
}

export const LEAVE_BLEND = 0.35

const PICK_UP_BLEND = 0.45
const PICK_UP_BLINK = 1.0
const IDLE_LIDS = 6
const ANGRY_SETTLE = [8.6, 0.4] as const

const shots: Readonly<Record<CallSegment, (t: number, idle: BotMascotPose) => CallShot>> = {
  pickUp: (t, idle) => ({
    t0: t,
    pose: withBlink(
      blended(idle, callingSwapPose(t), s01(t / PICK_UP_BLEND)),
      blinkAt(t, PICK_UP_BLINK)
    )
  }),
  calling: (t) => ({ t0: PICK_UP, pose: talkingPose(t % TALK_LOOP) }),
  hangUp: (t, idle) => hangingUp(t, settledInto(hangUpPose(t), idle, hangUpSettle(t))),
  angryHangUp: (t, idle) => {
    const t0 = PICK_UP + t
    const settle = s01((t0 - ANGRY_SETTLE[0]) / ANGRY_SETTLE[1])
    return { t0, pose: blended(callingSwapPose(t0), idle, settle) }
  }
}

export function callShot(
  segment: CallSegment,
  t: number,
  idle: BotMascotPose,
  leftCallAt?: number
): CallShot {
  const shot = shots[segment](t, idle)
  if (leftCallAt === undefined || t >= LEAVE_BLEND) return shot
  return { ...shot, pose: easedFrom(talkingPose(leftCallAt), shot.pose, t / LEAVE_BLEND) }
}

function hangingUp(t: number, pose: BotMascotPose): CallShot {
  if (t >= HUNG_UP) return { t0: PICK_UP, pose: { ...pose, fx: [] } }
  return { t0: PICK_UP, pose, phone: hangUpScene(t) }
}

function withBlink(pose: BotMascotPose, blink: number): BotMascotPose {
  return { ...pose, face: { ...pose.face, blink } }
}

function settledInto(from: BotMascotPose, idle: BotMascotPose, u: number): BotMascotPose {
  const pose = blended(from, idle, u)
  const own = from.face?.blink ?? 1
  const theirs = idle.face?.blink ?? 1
  return withBlink(pose, own + (theirs - own) * u ** IDLE_LIDS)
}

function blended(from: BotMascotPose, to: BotMascotPose, u: number): BotMascotPose {
  if (u <= 0) return from
  const fx = (onThePhone(from) ? from : to).fx ?? []
  if (u >= 1) return { ...to, fx }
  return { ...blendPoses(from, to, u), fx }
}

function easedFrom(from: BotMascotPose, to: BotMascotPose, u: number): BotMascotPose {
  return { ...blendPoses(from, to, s01(u)), fx: to.fx ?? [] }
}

const onThePhone = (pose: BotMascotPose): boolean => !!pose.fx?.some((f) => f.kind === "calling")
