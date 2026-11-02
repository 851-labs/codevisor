import { INK } from "../color/colors.js"
import type { Palette } from "../color/palette.js"
import { f2 } from "../geometry/math.js"
import type { BotMascotPose, Effect } from "../pose.js"
import type { RenderContext } from "../render/context.js"
import { star4 } from "../render/shine.js"
import { callingSvg } from "./calling.js"
import { clipboardSvg } from "./clipboard.js"
import { thinkingSvg } from "./thinking.js"

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
    case "sparkle":
      return star4(f.x, top + f.y, f.r, P.fx, P.outline, f.op)
    case "z":
      return sleepZ(f.x, f.y, f.s, f.op, P)
    case "tear":
      return tear(f.x, f.y, 11, f.op)
    case "clipboard":
      return clipboardSvg(ctx, P, f, lift)
    case "calling":
      return callingSvg(ctx, P, f, lift, pose.tilt || 0)
    case "think":
      return thinkingSvg(ctx, P, f, lift, pose.tilt || 0, pose.sy ?? 1)
    case "dot":
      return `<circle cx="${f2(f.x)}" cy="${f2(top + f.y)}" r="${f2(f.r)}" fill="${P.outline}" opacity="${f2(f.op)}"/>`
    case "puff":
      return `<circle cx="${f2(f.x)}" cy="${f2(top + f.y)}" r="${f2(f.r)}" fill="#C4C8D2" stroke="${P.outline}" stroke-width="2.5" opacity="${f2(f.op)}"/>`
    case "pop":
      return `<path d="M${f.x} ${f.y}l${f.dx} ${f.dy}" stroke="${P.eye}" stroke-width="7" stroke-linecap="round" opacity="${f2(f.op)}"/>`
    default:
      return ""
  }
}

function sleepZ(x: number, y: number, s: number, op: number, P: Palette): string {
  const h = 9 * s
  const d = `M${f2(x - h)} ${f2(y - h)}L${f2(x + h)} ${f2(y - h)}L${f2(x - h)} ${f2(y + h)}L${f2(x + h)} ${f2(y + h)}`
  return (
    `<g opacity="${f2(op)}"><path d="${d}" fill="none" stroke="${P.outline}" stroke-width="${9 * s}" stroke-linecap="round" stroke-linejoin="round"/>` +
    `<path d="${d}" fill="none" stroke="${P.fx}" stroke-width="${4 * s}" stroke-linecap="round" stroke-linejoin="round"/></g>`
  )
}

function tear(x: number, y: number, s: number, op: number): string {
  return (
    `<path d="M${x} ${y - 1.1 * s}C${x} ${y - 1.1 * s} ${x + 0.62 * s} ${y - 0.07 * s} ${x + 0.62 * s} ${y + 0.25 * s}C${x + 0.62 * s} ${y + 0.57 * s} ${x + 0.36 * s} ${y + 0.85 * s} ${x} ${y + 0.85 * s}` +
    `C${x - 0.36 * s} ${y + 0.85 * s} ${x - 0.62 * s} ${y + 0.57 * s} ${x - 0.62 * s} ${y + 0.25 * s}C${x - 0.62 * s} ${y - 0.07 * s} ${x} ${y - 1.1 * s} ${x} ${y - 1.1 * s}Z" fill="#9DCBFF" stroke="${INK}" stroke-width="3" opacity="${f2(op)}"/>`
  )
}
