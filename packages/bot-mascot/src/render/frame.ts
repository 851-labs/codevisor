import { bodyOutline, type Crease } from "../body/rig.js"
import { palette, type Palette } from "../color/palette.js"
import { drapeSvg } from "../drapes/drape.js"
import { effectsSvg } from "../effects/effects.js"
import { eyeSvg } from "../face/eye.js"
import { eyewearSvg } from "../face/eyewear.js"
import { faceState } from "../face/face-state.js"
import { makeupSvg } from "../face/makeup.js"
import { fa, f2 } from "../geometry/math.js"
import { hatSvg, hatTf } from "../hats/hats.js"
import { clothesSvg, SHADE_REGION, sleeveOf } from "../outfits/outfits.js"
import type { BotMascotPose } from "../pose.js"
import type { RenderContext } from "./context.js"

export const LIGHT = [6, -10] as const

export type Backdrop = "transparent" | "white"

export interface FrameOptions {
  readonly uid?: string
  readonly viewBox?: string
  readonly size?: number
  readonly backdrop?: Backdrop
}

export interface FrameParts {
  readonly tf: string
  readonly shadow: readonly [string, string, string]
  readonly d: string
  readonly eyeTf: string
  readonly fx: string
  readonly face: string
  readonly makeup: string
  readonly eyewear: string
  readonly drape: string
  readonly wear: string
  readonly wearOp: string
  readonly creases: string
  readonly hatTf: string
  readonly hat: string
}

const BACKDROPS: Readonly<Record<Backdrop, string | null>> = { transparent: null, white: "#FFFFFF" }

export function frameParts(
  ctx: RenderContext,
  P: Palette,
  pose: BotMascotPose,
  uid: string
): FrameParts {
  const sy = pose.sy ?? 1
  const sx = 2 - sy
  const lift = pose.y || 0
  const { d, creases, eyeTf } = bodyOutline(ctx.body, pose)
  const s = Math.max(0.25, 1 - lift / 280)
  const face = faceState(pose)
  return {
    tf: `translate(250 ${fa(412 - lift)}) rotate(${fa(pose.lean || 0)}) scale(${fa(sx)} ${fa(sy)}) translate(-250 -412)`,
    shadow: [fa(80 * s * sx), fa(7 * s), `rgba(20,20,30,${(0.16 * s).toFixed(4)})`],
    d,
    eyeTf,
    fx: effectsSvg(ctx, P, pose, lift),
    face: eyeSvg(P, face, uid),
    makeup: makeupSvg(P, face, uid),
    eyewear: eyewearSvg(P, face, uid),
    drape: drapeSvg(ctx.body, P, pose, uid),
    wear: clothesSvg(ctx.body, P, pose, uid),
    wearOp: fa(pose.wear?.clothesOp ?? 1),
    creases: creases.map((c) => creaseSvg(P, c)).join(""),
    hatTf: hatTf(ctx.body, pose, sx, sy),
    hat: hatSvg(P, pose.hat, uid)
  }
}

export function renderFrame(
  ctx: RenderContext,
  color: string | undefined,
  pose: BotMascotPose = {},
  opts: FrameOptions = {}
): string {
  const P = palette(color)
  const uid = opts.uid || "bm"
  const F = frameParts(ctx, P, pose, uid)
  const sl = sleeveOf(P, pose)
  const stops = P.body.map(([pos, c]) => `<stop offset="${pos}" stop-color="${c}"/>`).join("")
  const bg = BACKDROPS[opts.backdrop || "transparent"]
  const size = opts.size ? ` width="${opts.size}" height="${opts.size}"` : ""
  const gradientTop = ctx.body.zoned ? f2(186 - ctx.body.rise) : 186
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${opts.viewBox || "0 0 500 500"}"${size} class="bot-mascot-svg" data-r="root"${sl ? ` data-sleeve="${sl}"` : ""}>` +
    `<defs><linearGradient id="${uid}g" gradientUnits="userSpaceOnUse" x1="0" y1="${gradientTop}" x2="0" y2="412">${stops}</linearGradient>` +
    `<clipPath id="${uid}c"><path data-r="clip" d="${F.d}"/></clipPath>` +
    `<mask id="${uid}m" maskUnits="userSpaceOnUse" ${SHADE_REGION}><rect ${SHADE_REGION} fill="#fff"/><path data-r="mask" d="${F.d}" fill="#000" transform="translate(${LIGHT[0]} ${LIGHT[1]})"/></mask>` +
    `<filter id="${uid}b4" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="4"/></filter></defs>` +
    (bg ? `<rect width="500" height="500" fill="${bg}"/>` : "") +
    `<ellipse data-r="shadow" cx="250" cy="414.7" rx="${F.shadow[0]}" ry="${F.shadow[1]}" fill="${F.shadow[2]}" filter="url(#${uid}b4)"/>` +
    `<g data-r="tf" transform="${F.tf}">` +
    `<path data-r="body" d="${F.d}" fill="url(#${uid}g)" stroke="${P.outline}" stroke-width="16" stroke-linejoin="round" paint-order="stroke"/>` +
    `<g clip-path="url(#${uid}c)"><rect ${SHADE_REGION} fill="${P.shade}" mask="url(#${uid}m)"/></g>` +
    `<g clip-path="url(#${uid}c)"><g data-r="mkt" transform="${F.eyeTf}"><g data-r="makeup">${F.makeup}</g></g></g>` +
    `<g clip-path="url(#${uid}c)"><g data-r="eye" transform="${F.eyeTf}"><g data-r="face">${F.face}</g></g></g>` +
    `<g data-r="wear" clip-path="url(#${uid}c)" opacity="${F.wearOp}">${F.wear}</g>` +
    `<g data-r="creases">${F.creases}</g>` +
    `<g data-r="drape">${F.drape}</g>` +
    `<g clip-path="url(#${uid}c)"><g data-r="ewt" transform="${F.eyeTf}"><g data-r="eyewear">${F.eyewear}</g></g></g>` +
    `<g data-r="hat" transform="${F.hatTf}"><g data-r="hatc">${F.hat}</g></g></g>` +
    `<g data-r="fx">${F.fx}</g></svg>`
  )
}

function creaseSvg(P: Palette, { c, op }: Crease): string {
  const [a, b, e] = [c[0]!, c[1]!, c[2]!]
  return `<path d="M${f2(a[0])} ${f2(a[1])}Q${f2(b[0])} ${f2(b[1])} ${f2(e[0])} ${f2(e[1])}" fill="none" stroke="${P.outline}" stroke-width="5" stroke-linecap="round" opacity="${f2(op)}"/>`
}
