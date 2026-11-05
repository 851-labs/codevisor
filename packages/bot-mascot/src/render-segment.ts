import { callShot, type CallSegment } from "./animations/calling-segments.js"
import { renderCallingSwap } from "./animations/calling-swap.js"
import {
  armsFrameState,
  renderIdleWorking,
  type ArmsFrameState
} from "./animations/idle-working.js"
import { dressed, resolveConfig, type BotMascotConfig } from "./config.js"
import { gazeOrigin, lookingAt, type BotMascotGaze } from "./gaze/gaze.js"
import { idleAt } from "./moods/moods.js"
import type { BotMascotColor } from "./options.js"
import type { BotMascotPose } from "./pose.js"
import { renderContext, type RenderContext } from "./render/context.js"
import {
  botMascotSegments,
  WORKING_SWING,
  type BotMascotSegment,
  type SegmentFrame
} from "./segments.js"

export interface SegmentFrameOptions extends BotMascotConfig {
  readonly frame: SegmentFrame
  readonly gaze?: BotMascotGaze | null
  readonly viewBox: string
  readonly size?: number
  readonly uid?: string
}

interface Shot {
  readonly ctx: RenderContext
  readonly color: BotMascotColor
  readonly edit: (pose: BotMascotPose) => BotMascotPose
  readonly idle: (clock: number) => BotMascotPose
  readonly viewBox: string
  readonly uid: string
  readonly size?: number
}

type Renderer = (shot: Shot, frame: SegmentFrame) => string

export function renderBotMascotSegmentFrame(options: SegmentFrameOptions): string {
  const shot = shotFor(options)
  const frame = options.frame
  if (atHub(frame)) return idleFrame(shot, frame)
  return renderers[frame.segment](shot, frame)
}

const calling =
  (segment: CallSegment): Renderer =>
  (shot, frame) => {
    const { t0, pose, exit, phone } = callShot(
      segment,
      frame.t,
      shot.idle(frame.clock),
      frame.leftCallAt
    )
    return renderCallingSwap(shot.ctx, shot.color, t0, {
      viewBox: shot.viewBox,
      uid: shot.uid,
      pose: shot.edit(pose),
      ...(shot.size ? { size: shot.size } : {}),
      ...(exit === undefined ? {} : { exit }),
      ...(phone === undefined ? {} : { phone })
    })
  }

const working =
  (state: (frame: SegmentFrame, idle: Shot["idle"]) => ArmsFrameState): Renderer =>
  (shot, frame) =>
    renderIdleWorking(shot.ctx, shot.color, frame.clock, shot.viewBox, shot.uid, {
      state: state(frame, shot.idle),
      edit: shot.edit,
      ...(shot.size ? { size: shot.size } : {})
    })

const idleFrame: Renderer = (shot, frame) =>
  renderIdleWorking(shot.ctx, shot.color, frame.clock, shot.viewBox, shot.uid, {
    state: { pose: shot.idle(frame.clock), w: 0, tw: null },
    edit: shot.edit,
    ...(shot.size ? { size: shot.size } : {})
  })

const workingSince = (frame: SegmentFrame): number => frame.clock - (frame.since + frame.t)

const atWork = working((f, idle) =>
  armsFrameState(f.clock, { in: workingSince(f), out: Infinity, swing: WORKING_SWING }, idle)
)

const renderers: Readonly<Record<BotMascotSegment, Renderer>> = {
  idle: idleFrame,
  pickUp: calling("pickUp"),
  calling: calling("calling"),
  hangUp: calling("hangUp"),
  angryHangUp: calling("angryHangUp"),
  startWorking: atWork,
  working: atWork,
  stopWorking: working((f, idle) =>
    armsFrameState(f.clock, { in: workingSince(f), out: f.clock - f.t, swing: WORKING_SWING }, idle)
  )
}

function shotFor(options: SegmentFrameOptions): Shot {
  const config = resolveConfig(options)
  const uid = options.uid ?? "bm"
  const ctx = renderContext({ idPrefix: uid })
  const origin = gazeOrigin(ctx.body)
  return {
    ctx,
    color: config.color,
    edit: dressed(config),
    idle: (clock) => lookingAt(idleAt(clock), options.gaze, origin),
    viewBox: options.viewBox,
    uid,
    ...(options.size ? { size: options.size } : {})
  }
}

function atHub(frame: SegmentFrame): boolean {
  const segment = botMascotSegments[frame.segment]
  const leaving = segment.from === "idle" && frame.t <= 0
  const back = segment.to === "idle" && frame.t >= segment.seconds
  return leaving || back
}
