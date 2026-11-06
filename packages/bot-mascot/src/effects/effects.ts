import { zStroke } from "../animations/sleeping.js"
import { bodyTop, type Palette } from "../color/palette.js"
import { f2 } from "../geometry/math.js"
import type { BotMascotPose, Effect, SleepZEffect } from "../pose.js"
import type { RenderContext } from "../render/context.js"
import { callingSvg } from "./calling.js"
import { clipboardSvg } from "./clipboard.js"

export function effectsSvg(
  ctx: RenderContext,
  P: Palette,
  pose: BotMascotPose,
  lift: number
): string {
  let out = ""
  for (const f of pose.fx || []) {
    if (f.op <= 0.005) continue
    out += effectSvg(ctx, P, pose, lift, f)
  }
  return out
}

function effectSvg(
  ctx: RenderContext,
  P: Palette,
  pose: BotMascotPose,
  lift: number,
  f: Effect
): string {
  const top = 186 - lift
  switch (f.kind) {
    case "clipboard":
      return clipboardSvg(ctx, P, f, lift)
    case "calling":
      return callingSvg(ctx, P, f, lift, pose.tilt || 0)
    case "dot":
      return `<circle cx="${f2(f.x)}" cy="${f2(top + f.y)}" r="${f2(f.r)}" fill="${P.outline}" opacity="${f2(f.op)}"/>`
    case "z":
      return sleepZSvg(P, f)
    case "puff":
      return `<circle cx="${f2(f.x)}" cy="${f2(top + f.y)}" r="${f2(f.r)}" fill="#C4C8D2" stroke="${P.outline}" stroke-width="2.5" opacity="${f2(f.op)}"/>`
    default:
      return ""
  }
}

export const SLEEP_Z_INK_WIDTH = 15
export const SLEEP_Z_CORE_WIDTH = 7.5

function sleepZSvg(P: Palette, z: SleepZEffect): string {
  const d = zStroke(z)
    .map(([x, y], i) => `${i ? "L" : "M"}${f2(x)} ${f2(y)}`)
    .join("")
  const stroke = (color: string, width: number) =>
    `<path d="${d}" fill="none" stroke="${color}" stroke-width="${width}" stroke-linecap="round" stroke-linejoin="round"/>`
  return `<g data-r="z" opacity="${f2(z.op)}">${stroke(P.outline, SLEEP_Z_INK_WIDTH)}${stroke(bodyTop(P), SLEEP_Z_CORE_WIDTH)}</g>`
}
