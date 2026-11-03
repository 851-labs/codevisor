import type { Palette } from "../color/palette.js"
import { f2 } from "../geometry/math.js"
import type { BotMascotPose, Effect } from "../pose.js"
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
    case "puff":
      return `<circle cx="${f2(f.x)}" cy="${f2(top + f.y)}" r="${f2(f.r)}" fill="#C4C8D2" stroke="${P.outline}" stroke-width="2.5" opacity="${f2(f.op)}"/>`
    default:
      return ""
  }
}
