import { CALLING_LOOP, callingPose } from "../effects/calling.js"
import { clipboardPose } from "../effects/clipboard.js"
import { thinkingPose } from "../effects/thinking.js"
import type { BotMascotPose, FacePose, LegPose } from "../pose.js"
import {
  HAPPY_LOOP,
  happyPose,
  IDLE_LOOP,
  idlePose,
  SAD_LOOP,
  sadPose,
  SLEEPY_LOOP,
  sleepyPose,
  SURPRISED_LOOP,
  surprisedPose
} from "./expressions.js"

export interface Mood {
  readonly title: string
  readonly loop: number | null
  readonly still: number
  readonly pose: (t: number) => BotMascotPose
}

export const botMascotMoods = {
  idle: { title: "Idle", loop: IDLE_LOOP, still: 0, pose: idlePose },
  happy: { title: "Happy", loop: HAPPY_LOOP, still: 1.4, pose: happyPose },
  sad: { title: "Sad", loop: SAD_LOOP, still: 3.4, pose: sadPose },
  sleepy: { title: "Sleepy", loop: SLEEPY_LOOP, still: 1.6, pose: sleepyPose },
  surprised: { title: "Surprised", loop: SURPRISED_LOOP, still: 0.95, pose: surprisedPose },
  thinking: { title: "Thinking", loop: null, still: 1.6, pose: thinkingPose },
  working: { title: "Working", loop: null, still: 1.2, pose: clipboardPose },
  calling: { title: "Calling", loop: CALLING_LOOP, still: 1.5, pose: callingPose }
} as const satisfies Readonly<Record<string, Mood>>

export type BotMascotMood = keyof typeof botMascotMoods

export const isBotMascotMood = (key: string | undefined): key is BotMascotMood =>
  key !== undefined && Object.hasOwn(botMascotMoods, key)

export const idleAt = (t: number): BotMascotPose => idlePose(t % IDLE_LOOP)

type Mixer = (x: number | undefined, y: number | undefined, k: string) => number

const REST_VALUES: Readonly<Record<string, number>> = {
  sy: 1,
  blink: 1,
  wide: 1,
  cheeks: 1,
  cheekOp: 1,
  glint: 1
}

export function blendPoses(a: BotMascotPose, b: BotMascotPose, u: number): BotMascotPose {
  const m: Mixer = (x, y, k) => {
    const p = x ?? REST_VALUES[k] ?? 0
    const q = y ?? REST_VALUES[k] ?? 0
    return p + (q - p) * u
  }
  const L = blendLegs(a.L, b.L, m)
  const R = blendLegs(a.R, b.R, m)
  return {
    ...b,
    y: m(a.y, b.y, "y"),
    lean: m(a.lean, b.lean, "lean"),
    sy: m(a.sy, b.sy, "sy"),
    tilt: m(a.tilt, b.tilt, "tilt"),
    twist: m(a.twist, b.twist, "twist"),
    shift: m(a.shift, b.shift, "shift"),
    spin: m(a.spin, b.spin, "spin"),
    ...(L ? { L } : {}),
    ...(R ? { R } : {}),
    face: blendFaces(a.face || {}, b.face || {}, u, m),
    fx: [
      ...(a.fx || []).map((f) => ({ ...f, op: (f.op ?? 1) * (1 - u) })),
      ...(b.fx || []).map((f) => ({ ...f, op: (f.op ?? 1) * u }))
    ]
  }
}

function blendLegs(
  la: LegPose | undefined,
  lb: LegPose | undefined,
  m: Mixer
): LegPose | undefined {
  if (!la && !lb) return lb
  return {
    rot: m(la?.rot, lb?.rot, "rot"),
    lift: m(la?.lift, lb?.lift, "lift"),
    dx: m(la?.dx, lb?.dx, "dx"),
    bend: m(la?.bend, lb?.bend, "bend"),
    stretch: m(la?.stretch, lb?.stretch, "stretch")
  }
}

function blendFaces(fa: FacePose, fb: FacePose, u: number, m: Mixer): FacePose {
  const blink = m(fa.blink, fb.blink, "blink")
  const swapsMode = (fa.mode || "open") !== (fb.mode || "open")
  return {
    ...(u < 0.5 ? fa : fb),
    turn: m(fa.turn, fb.turn, "turn"),
    up: m(fa.up, fb.up, "up"),
    blink: swapsMode ? Math.min(blink, 1 - 0.92 * Math.sin(Math.PI * u)) : blink,
    wide: m(fa.wide, fb.wide, "wide"),
    cheeks: m(fa.cheeks, fb.cheeks, "cheeks"),
    cheekOp: m(fa.cheekOp, fb.cheekOp, "cheekOp"),
    glint: m(fa.glint, fb.glint, "glint")
  }
}
