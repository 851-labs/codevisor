import { cubicPoint, type Point } from "../geometry/math.js"
import { botMascotMoods } from "../moods/moods.js"
import type { BotMascotPose } from "../pose.js"
import { renderContext, withHands, type RenderContext } from "../render/context.js"
import { renderFrame } from "../render/frame.js"
import { svgTransform } from "../render/svg-parts.js"
import type { ArmProp, PosedArm } from "./arm-pose.js"
import { compose } from "./compose.js"

export interface RigDrawOptions {
  readonly uid?: string
  readonly pal: string
  readonly pose?: BotMascotPose
  readonly underHands?: string
}

const PHONE_GROUP =
  /<g transform="translate\([^)]*\) rotate\([^)]*\) scale\(([-\d.]+)\)">([^]*?)<\/g><\/g>/
const CALLING_HAND = /<rect [^>]*fill="url\(#[^")]*calling\d+\)"[^>]*\/>/g
const SILHOUETTE = /<path d="([^"]+)" fill="none" stroke="[^"]+" stroke-width="10"/
const VERTEX = /[ML]([-\d.]+) ([-\d.]+)/g
const HANDLE: readonly [Point, Point, Point, Point] = [
  [-17, -38],
  [27, -41],
  [27, 41],
  [-17, 38]
]

const phones = new Map<string, ArmProp>()

export function drawRig(
  ctx: RenderContext,
  s: string,
  poses: ReadonlyArray<PosedArm>,
  opts: RigDrawOptions
): string {
  const tf = svgTransform(s)
  const live = poses.filter((p) => p.arm)
  const items = live.map((p) => ({
    side: p.side,
    arm: p.arm!,
    layer: p.layer,
    frontClip: p.frontClip,
    over: p.over
  }))
  const c = compose(ctx, s, items, {
    uid: opts.uid || "rg",
    pal: opts.pal,
    blush: 1,
    ...(opts.pose ? { pose: opts.pose } : {})
  })
  const top = live
    .map((p) => {
      const hand = c.tops[p.side] || ""
      if (!p.prop) return hand ? `<g transform="${tf}">${hand}</g>` : ""
      const matrix = p.prop.M.map((v) => v.toFixed(4)).join(" ")
      return `<g transform="${tf}"><g transform="matrix(${matrix})">${p.prop.svg}</g>${hand}</g>`
    })
    .join("")
  const above = (opts.underHands ?? "") + top
  return above ? c.svg.replace(/<\/svg>$/, `${above}</svg>`) : c.svg
}

export function phoneProp(pal: string): ArmProp {
  const cached = phones.get(pal)
  if (cached) return cached
  const prop = buildPhoneProp(pal)
  phones.set(pal, prop)
  return prop
}

function buildPhoneProp(pal: string): ArmProp {
  const ctx = withHands(renderContext(), () => "")
  const s = renderFrame(ctx, pal, botMascotMoods.calling.pose(1.8), { uid: "pp" })
  const m = PHONE_GROUP.exec(s)
  const scale = Number(m?.[1])
  const svg = (m?.[2] ?? "").replace(CALLING_HAND, "")
  const sm = SILHOUETTE.exec(svg)?.[1] ?? ""
  const sil = [...sm.matchAll(VERTEX)].map((q): Point => [+q[1]!, +q[2]!])
  const middle = cubicPoint(HANDLE[0], HANDLE[1], HANDLE[2], HANDLE[3], 0.5)
  return {
    svg,
    scale,
    grip: [(6.4 + 21.8) / 2, middle[1]],
    gripDir: [-1, 0],
    sil: outset(sil, 6.3),
    past: 17,
    over: "hand",
    hand: { len: 19 },
    holdFrom: "back"
  }
}

function outset(sil: ReadonlyArray<Point>, by: number): ReadonlyArray<Point> {
  let ar = 0
  for (let i = 0; i < sil.length; i++) {
    const a = sil[i]!
    const b = sil[(i + 1) % sil.length]!
    ar += a[0] * b[1] - b[0] * a[1]
  }
  const sg = ar > 0 ? 1 : -1
  return sil.map((p, i) => {
    const a = sil[(i - 1 + sil.length) % sil.length]!
    const b = sil[(i + 1) % sil.length]!
    const t: Point = [b[0] - a[0], b[1] - a[1]]
    const mm = Math.hypot(...t) || 1
    return [p[0] + sg * (t[1] / mm) * by, p[1] - sg * (t[0] / mm) * by]
  })
}
