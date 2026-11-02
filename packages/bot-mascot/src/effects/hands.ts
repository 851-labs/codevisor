import { bodyBottom, bodyTop, type Palette } from "../color/palette.js"
import type { Point } from "../geometry/math.js"
import type { RenderContext } from "../render/context.js"

export type HandPose = "open" | "thumbsUp" | "indexUp" | "chin" | "point" | "typing"

export interface HandParams {
  readonly thumb?: number
  readonly [finger: number]: number | undefined
}

export interface HandOptions {
  readonly pose?: HandPose
  readonly x: number
  readonly y: number
  readonly rot?: number
  readonly s?: number
  readonly mirror?: boolean
  readonly p?: HandParams
  readonly op?: number
}

interface HandShape {
  readonly parts: string
  readonly segs?: string
  readonly creases?: string
  readonly rot?: number
}

const cap = (bx: number, by: number, ang: number, len: number, w: number): string =>
  `<rect x="${-w / 2}" y="${-len}" width="${w}" height="${len + w / 2}" rx="${w / 2}" transform="translate(${bx} ${by}) rotate(${ang})"/>`

const oval = (cx: number, cy: number, rx: number, ry: number, a = 0): string =>
  `<ellipse cx="${cx}" cy="${cy}" rx="${rx}" ry="${ry}" transform="rotate(${a} ${cx} ${cy})"/>`

const dot = (cx: number, cy: number, r: number): string =>
  `<circle cx="${cx}" cy="${cy}" r="${r}"/>`

const crease = (d: string, O: string): string =>
  `<path d="${d}" fill="none" stroke="${O}" stroke-width="3.6" stroke-linecap="round"/>`

const roundRect = (
  x: number,
  y: number,
  w: number,
  h: number,
  r: number,
  a = 0,
  ox = x,
  oy = y
): string =>
  `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${r}" transform="rotate(${a} ${ox} ${oy})"/>`

const open = (): HandShape => ({
  parts:
    oval(0, 0, 21, 19) +
    cap(-11, -7, -24, 26, 12.5) +
    cap(0, -11, 0, 31, 12.5) +
    cap(11, -7, 24, 27, 12.5) +
    cap(-18, 5, -72, 21, 12.5),
  creases: "M-6 -14L-4.5 -6M6 -14L4.5 -6M-14 -2L-10 2"
})

const thumbsUp = (p: HandParams = {}): HandShape => {
  const fingers =
    roundRect(-2, -8, 25, 12, 6) + roundRect(-2, 3, 25, 12, 6) + roundRect(-3, 14, 22, 12, 6)
  return {
    parts:
      roundRect(-20, -8, 32, 34, 13) +
      fingers +
      roundRect(-15, -30, 15, 28, 7.5, p.thumb ?? -6, -8, -4),
    segs: fingers
  }
}

const indexUp = (): HandShape => ({
  parts:
    roundRect(-20, -8, 40, 34, 14) +
    roundRect(-18, -48, 13, 50, 6.5) +
    dot(1.5, -8, 7.5) +
    dot(14, -7, 7) +
    cap(-16, 12, -52, 20, 12),
  creases: "M-5 -15L-5 -7M7.8 -14L7.8 -7"
})

const typing = (p: HandParams = {}): HandShape => {
  const f = (x: number, a: number, k: number): string =>
    `<rect x="${x - 6.25}" y="0" width="12.5" height="${30 - 9 * (p[k] || 0)}" rx="6.25" transform="rotate(${a} ${x} 0)"/>`
  return {
    parts:
      roundRect(-22, -18, 44, 24, 12) +
      f(-12.5, 7, 0) +
      f(0, 0, 1) +
      f(12.5, -7, 2) +
      cap(-18, -4, 228, 17, 12),
    creases: "M-6.2 6L-7.6 19M6.2 6L7.6 19"
  }
}

export const handPoses: Readonly<Record<HandPose, (p?: HandParams) => HandShape>> = {
  open,
  thumbsUp,
  indexUp,
  chin: indexUp,
  point: () => ({ ...indexUp(), rot: 90 }),
  typing
}

export function floatingHand(ctx: RenderContext, P: Palette, o: HandOptions): string {
  const { pose = "open", x, y, rot = 0, s = 1, mirror = false, p = {}, op = 1 } = o
  const id = `${ctx.idPrefix}hd${++ctx.ids.hands}`
  const O = P.outline
  const { parts, segs = "", creases = "", rot: built = 0 } = handPoses[pose](p)
  const [lx, ly] = lightNudge(rot, mirror, built).map((v) => v.toFixed(2))
  const tf = `translate(${x} ${y}) rotate(${rot}) scale(${mirror ? -s : s} ${s}) rotate(${built})`
  return (
    `<g transform="${tf}" opacity="${op}"><defs><linearGradient id="${id}g" gradientUnits="userSpaceOnUse" x1="0" y1="-40" x2="0" y2="28"><stop offset="0" stop-color="${bodyTop(P)}"/><stop offset="1" stop-color="${bodyBottom(P)}"/></linearGradient>` +
    `<clipPath id="${id}c">${parts}</clipPath><mask id="${id}m" maskUnits="userSpaceOnUse" x="-90" y="-90" width="180" height="180"><rect x="-90" y="-90" width="180" height="180" fill="#fff"/><g fill="#000" transform="translate(${lx} ${ly})">${parts}</g></mask></defs>` +
    `<g fill="${O}" stroke="${O}" stroke-width="13" stroke-linejoin="round">${parts}</g><g fill="url(#${id}g)">${parts}</g>` +
    (segs
      ? `<g fill="url(#${id}g)" stroke="${O}" stroke-width="4" stroke-linejoin="round">${segs}</g>`
      : "") +
    `<g clip-path="url(#${id}c)"><rect x="-90" y="-90" width="180" height="180" fill="${P.shade}" mask="url(#${id}m)"/></g>` +
    (creases ? crease(creases, O) : "") +
    `</g>`
  )
}

export function handPop(P: Palette, x: number, y: number, u: number): string {
  if (u <= 0 || u >= 1) return ""
  return `<circle cx="${x}" cy="${y}" r="${(18 + 26 * u).toFixed(1)}" fill="none" stroke="${P.outline}" stroke-width="${(5 * (1 - u)).toFixed(2)}" opacity="${(0.7 * (1 - u)).toFixed(2)}"/>`
}

function lightNudge(rot: number, mirror: boolean, built: number): Point {
  let L = turn([3, -5], -rot)
  if (mirror) L = [-L[0], L[1]]
  return turn(L, -built)
}

function turn(v: Point, deg: number): Point {
  const a = (deg * Math.PI) / 180
  return [v[0] * Math.cos(a) - v[1] * Math.sin(a), v[0] * Math.sin(a) + v[1] * Math.cos(a)]
}
