import { bodyOf, officialBodyZones, type Body, type BodyZones } from "../body/zones.js"
import type { Palette } from "../color/palette.js"
import { DrapeSwings } from "../drapes/redrape.js"
import { floatingHand, type HandOptions } from "../effects/hands.js"

export type HandDrawer = (P: Palette, o: HandOptions) => string

export interface IdCounters {
  hands: number
  clipboard: number
  calling: number
}

export interface RenderContext {
  readonly body: Body
  readonly hands: HandDrawer
  readonly ids: IdCounters
  readonly idPrefix: string
  readonly swings: DrapeSwings
  readonly now: number
}

export interface RenderContextOptions {
  readonly zones?: BodyZones | null | undefined
  readonly idPrefix?: string
  readonly swings?: DrapeSwings
  readonly now?: number
}

export function renderContext(options: RenderContextOptions = {}): RenderContext {
  const ctx: RenderContext = {
    body: bodyOf(options.zones === undefined ? officialBodyZones : options.zones),
    hands: (P, o) => floatingHand(ctx, P, o),
    ids: { hands: 0, clipboard: 0, calling: 0 },
    idPrefix: options.idPrefix ?? "",
    swings: options.swings ?? new DrapeSwings(),
    now: options.now ?? 0
  }
  return ctx
}

export const withHands = (ctx: RenderContext, hands: HandDrawer): RenderContext => ({
  ...ctx,
  hands
})
