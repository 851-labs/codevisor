import { renderIdleWorking } from "./animations/idle-working.js"
import { WAITING_LOOP } from "./animations/waiting.js"
import { dressed, resolveConfig, type BotMascotConfig } from "./config.js"
import { CLIPBOARD_LOOP, CLIPBOARD_POP } from "./effects/clipboard.js"
import { IDLE_LOOP } from "./moods/expressions.js"
import { renderBotMascotSegmentFrame } from "./render-segment.js"
import { renderContext } from "./render/context.js"
import { soloFrame } from "./segments.js"

export type BotMascotLoop = "idle" | "working" | "waiting"

export interface LoopTiming {
  readonly start: number
  readonly seconds: number
}

export interface LoopFrameOptions extends BotMascotConfig {
  readonly loop: BotMascotLoop
  readonly t: number
  readonly viewBox: string
  readonly size?: number
  readonly uid?: string
}

export const botMascotLoops: Readonly<Record<BotMascotLoop, LoopTiming>> = {
  idle: { start: 0, seconds: IDLE_LOOP },
  working: { start: CLIPBOARD_POP + CLIPBOARD_LOOP, seconds: CLIPBOARD_LOOP },
  waiting: { start: 0, seconds: WAITING_LOOP }
}

const FIGURE_CENTER_X = 250
const FIGURE_GROUND_Y = 428
const FIGURE_HEADROOM_TOP_Y = 30
const FIGURE_SIDE = FIGURE_GROUND_Y - FIGURE_HEADROOM_TOP_Y

export const FIGURE_VIEW_BOX = [
  FIGURE_CENTER_X - FIGURE_SIDE / 2,
  FIGURE_HEADROOM_TOP_Y,
  FIGURE_SIDE,
  FIGURE_SIDE
].join(" ")

export function renderBotMascotLoopFrame(options: LoopFrameOptions): string {
  const timing = botMascotLoops[options.loop]
  const t = timing.start + (options.t % timing.seconds)
  if (options.loop === "waiting") return waitingFrame(options, t)
  return armsFrame(options, options.loop, t)
}

function armsFrame(options: LoopFrameOptions, mode: "idle" | "working", t: number): string {
  const config = resolveConfig(options)
  const uid = options.uid ?? "bm"
  const ctx = renderContext({ idPrefix: uid })
  return renderIdleWorking(ctx, config.color, t, options.viewBox, uid, {
    mode,
    edit: dressed(config),
    ...(options.size ? { size: options.size } : {})
  })
}

function waitingFrame(options: LoopFrameOptions, t: number): string {
  const { loop: _loop, t: _t, ...look } = options
  return renderBotMascotSegmentFrame({ ...look, frame: soloFrame("waiting", t) })
}
