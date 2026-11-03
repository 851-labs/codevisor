import { renderIdleWorking } from "./animations/idle-working.js"
import { dressed, resolveConfig, type BotMascotConfig } from "./config.js"
import { CLIPBOARD_LOOP, CLIPBOARD_POP } from "./effects/clipboard.js"
import { IDLE_LOOP } from "./moods/expressions.js"
import { renderContext } from "./render/context.js"

export type BotMascotLoop = "idle" | "working"

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
  working: { start: CLIPBOARD_POP + CLIPBOARD_LOOP, seconds: CLIPBOARD_LOOP }
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
  const config = resolveConfig(options)
  const uid = options.uid ?? "bm"
  const ctx = renderContext({ idPrefix: uid })
  const t = botMascotLoops[options.loop].start + (options.t % botMascotLoops[options.loop].seconds)
  return renderIdleWorking(ctx, config.color, t, options.viewBox, uid, {
    mode: options.loop,
    edit: dressed(config),
    ...(options.size ? { size: options.size } : {})
  })
}
