import { renderCallingSwap, callingSwapPose } from "./animations/calling-swap.js"
import { renderIdleWorking } from "./animations/idle-working.js"
import type { BodyZones } from "./body/zones.js"
import { dressed, portraitViewBox, resolveConfig, type BotMascotConfig } from "./config.js"
import { botMascotMoods } from "./moods/moods.js"
import { renderContext } from "./render/context.js"
import type { Backdrop } from "./render/frame.js"

export interface StaticRenderOptions extends BotMascotConfig {
  readonly size?: number
  readonly viewBox?: string
  readonly backdrop?: Backdrop
  readonly uid?: string
  readonly zones?: BodyZones | null
}

export const CALLING_STILL = 2

export function renderBotMascotSvg(options: StaticRenderOptions = {}): string {
  const config = resolveConfig(options)
  const ctx = renderContext({ zones: options.zones, idPrefix: options.uid ?? "bm" })
  const uid = options.uid ?? "bm"
  const viewBox = options.viewBox ?? portraitViewBox(config.hat)
  const frame = {
    viewBox,
    uid,
    ...(options.size ? { size: options.size } : {}),
    ...(options.backdrop ? { backdrop: options.backdrop } : {})
  }
  const edit = dressed(config)
  if (config.mood === "calling") {
    return renderCallingSwap(ctx, config.color, CALLING_STILL, {
      ...frame,
      pose: edit(callingSwapPose(CALLING_STILL))
    })
  }
  return renderIdleWorking(ctx, config.color, botMascotMoods[config.mood].still, viewBox, uid, {
    ...frame,
    mode: config.mood,
    edit
  })
}
