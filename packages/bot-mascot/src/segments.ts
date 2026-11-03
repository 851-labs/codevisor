import { callSeconds } from "./animations/calling-segments.js"
import { CLIPBOARD_LOOP } from "./effects/clipboard.js"
import { IDLE_LOOP } from "./moods/expressions.js"

export type BotMascotState = "idle" | "calling" | "working"

export type BotMascotSegment =
  | "idle"
  | "pickUp"
  | "calling"
  | "hangUp"
  | "angryHangUp"
  | "startWorking"
  | "working"
  | "stopWorking"

export type BotMascotRequest = "idle" | "calling" | "working" | "hangUp" | "angryHangUp"

export interface SegmentInfo {
  readonly title: string
  readonly from: BotMascotState
  readonly to: BotMascotState
  readonly seconds: number
  readonly loops: boolean
}

export interface SequenceStep {
  readonly segment: BotMascotSegment
  readonly seconds?: number
}

export interface SegmentFrame {
  readonly segment: BotMascotSegment
  readonly t: number
  readonly clock: number
  readonly since: number
  readonly leftCallAt?: number
}

export interface BotMascotSequence {
  readonly steps: ReadonlyArray<Required<SequenceStep>>
  readonly seconds: number
  readonly at: (t: number) => SegmentFrame
}

export const WORKING_SWING = 0.65

const CYCLE_EDGE = 1e-6

const loops: Readonly<Record<BotMascotState, BotMascotSegment>> = {
  idle: "idle",
  calling: "calling",
  working: "working"
}

export const botMascotSegments: Readonly<Record<BotMascotSegment, SegmentInfo>> = {
  idle: { title: "Idle", from: "idle", to: "idle", seconds: IDLE_LOOP, loops: true },
  pickUp: segmentInfo("Pick up", "idle", "calling", callSeconds.pickUp),
  calling: {
    ...segmentInfo("Calling", "calling", "calling", callSeconds.calling),
    loops: true
  },
  hangUp: segmentInfo("Hang up", "calling", "idle", callSeconds.hangUp),
  angryHangUp: segmentInfo("Angry hang-up", "calling", "idle", callSeconds.angryHangUp),
  startWorking: segmentInfo("Start working", "idle", "working", WORKING_SWING),
  working: { ...segmentInfo("Working", "working", "working", CLIPBOARD_LOOP), loops: true },
  stopWorking: segmentInfo("Stop working", "working", "idle", WORKING_SWING)
}

export const botMascotSegmentIds: ReadonlyArray<BotMascotSegment> =
  Object.keys(botMascotSegments).filter(isBotMascotSegment)

export const canFollow = (before: BotMascotSegment, after: BotMascotSegment): boolean =>
  botMascotSegments[before].to === botMascotSegments[after].from

export const loopOf = (state: BotMascotState): BotMascotSegment => loops[state]

export function botMascotRoute(
  from: BotMascotState,
  request: BotMascotRequest
): ReadonlyArray<BotMascotSegment> {
  if (request === "hangUp" || request === "angryHangUp") return endingCall(from, request)
  if (request === from) return [loopOf(from)]
  return [...toIdle(from), ...fromIdle(request), loopOf(request)]
}

export function botMascotSequence(steps: ReadonlyArray<SequenceStep>): BotMascotSequence {
  const timed = steps.map((step) => ({
    segment: step.segment,
    seconds: step.seconds ?? botMascotSegments[step.segment].seconds
  }))
  assertChained(timed)
  const starts = startTimes(timed)
  const seconds = starts[timed.length]!
  return { steps: timed, seconds, at: (t) => frameAt(timed, starts, clamped(t, seconds)) }
}

export const soloFrame = (segment: BotMascotSegment, t: number): SegmentFrame => ({
  segment,
  t,
  clock: t,
  since: segment === "working" || segment === "stopWorking" ? WORKING_SWING : 0
})

function isBotMascotSegment(id: string): id is BotMascotSegment {
  return Object.hasOwn(botMascotSegments, id)
}

function segmentInfo(
  title: string,
  from: BotMascotState,
  to: BotMascotState,
  seconds: number
): SegmentInfo {
  return { title, from, to, seconds, loops: false }
}

function endingCall(
  from: BotMascotState,
  ending: "hangUp" | "angryHangUp"
): ReadonlyArray<BotMascotSegment> {
  if (from !== "calling") return [loopOf(from)]
  return [ending, "idle"]
}

function toIdle(from: BotMascotState): ReadonlyArray<BotMascotSegment> {
  if (from === "calling") return ["hangUp"]
  if (from === "working") return ["stopWorking"]
  return []
}

function fromIdle(to: BotMascotState): ReadonlyArray<BotMascotSegment> {
  if (to === "calling") return ["pickUp"]
  if (to === "working") return ["startWorking"]
  return []
}

function assertChained(steps: ReadonlyArray<Required<SequenceStep>>): void {
  for (let i = 1; i < steps.length; i++) {
    const before = steps[i - 1]!.segment
    const after = steps[i]!.segment
    if (!canFollow(before, after)) throw new Error(`${after} can't follow ${before}`)
  }
}

function startTimes(steps: ReadonlyArray<Required<SequenceStep>>): ReadonlyArray<number> {
  const starts = [0]
  for (const step of steps) starts.push(starts[starts.length - 1]! + step.seconds)
  return starts
}

function frameAt(
  steps: ReadonlyArray<Required<SequenceStep>>,
  starts: ReadonlyArray<number>,
  t: number
): SegmentFrame {
  const i = stepIndexAt(starts, t)
  const step = steps[i]!
  const leftCallAt = i > 0 ? midCallPhase(steps[i - 1]!) : undefined
  return {
    segment: step.segment,
    t: t - starts[i]!,
    clock: t,
    since: sinceAway(steps, starts, i),
    ...(leftCallAt === undefined ? {} : { leftCallAt })
  }
}

function midCallPhase(step: Required<SequenceStep>): number | undefined {
  if (step.segment !== "calling") return undefined
  const cycle = botMascotSegments.calling.seconds
  const phase = step.seconds % cycle
  const midCycle = phase > CYCLE_EDGE && cycle - phase > CYCLE_EDGE
  return midCycle ? phase : undefined
}

function stepIndexAt(starts: ReadonlyArray<number>, t: number): number {
  let i = 0
  while (i < starts.length - 2 && t >= starts[i + 1]!) i++
  return i
}

function sinceAway(
  steps: ReadonlyArray<Required<SequenceStep>>,
  starts: ReadonlyArray<number>,
  i: number
): number {
  let first = i
  while (first > 0 && botMascotSegments[steps[first]!.segment].from !== "idle") first--
  return starts[i]! - starts[first]!
}

const clamped = (t: number, seconds: number): number => Math.min(seconds, Math.max(0, t))
