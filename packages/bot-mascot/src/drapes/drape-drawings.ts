import { CREAM, GOLD, litGradient, mix } from "../color/colors.js"
import type { Palette } from "../color/palette.js"
import { f2, polylineD, type Point } from "../geometry/math.js"
import { shouldered } from "../outfits/garment-kit.js"
import { TIE_DROP } from "../outfits/outfits.js"
import { star5 } from "../render/shine.js"
import { anchorAt } from "./anchors.js"
import { skirt, strip, tipOf, type DrapeContext } from "./skirt.js"

export type DrapeDrawing = (P: Palette, A: string, ctx: DrapeContext, uid: string) => string

const TIE_KNOT: ReadonlyArray<Point> = [
  [240, 319],
  [260, 319],
  [256, 331],
  [244, 331]
]

const ROBE_STARS: ReadonlyArray<readonly [number, number, number, number]> = [
  [0.23, 0.29, 5.5, 10],
  [0.77, 0.27, 5.5, -14],
  [0.3, 0.72, 5.5, 24],
  [0.68, 0.7, 6.5, 4],
  [0.5, 0.8, 4.5, -20],
  [0.86, 0.79, 4.5, 30],
  [0.13, 0.8, 4.5, -6]
]

const ring =
  (base: number, dip: number) =>
  (x: number): number =>
    base + dip * (1 - Math.min(1, ((x - 250) / 92) ** 2))

export const drapePiece = (uid: string, i: number, inner: string): string =>
  `<g id="${uid}dt${i}">${inner}</g>`

export function tie(P: Palette, A: string, ctx: DrapeContext, uid: string): string {
  const { body, pose } = ctx
  const o = ctx.dangles[0]!
  const S = anchorAt(body, pose, o.anchor)
  const T = tipOf(ctx, 0)
  const knot = polylineD(TIE_KNOT.map(([x, y]) => anchorAt(body, pose, [x, y + TIE_DROP])))
  const st = strip(S, T, o.L, (u) => 5.6 + 3.2 * Math.min(u / 0.86, 1), 0.86)
  const blade = polylineD([...st.left, T, ...st.right.toReversed()])
  return (
    `<defs><linearGradient id="${uid}tl" x1=".8" y1="0" x2=".2" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".2"/></linearGradient></defs>` +
    drapePiece(
      uid,
      0,
      `<path d="${blade}" fill="${A}" stroke="${P.outline}" stroke-width="10" stroke-linejoin="round" paint-order="stroke"/><path d="${blade}" fill="url(#${uid}tl)"/>`
    ) +
    `<path d="${knot}" fill="${mix(A, "#000000", 0.12)}" stroke="${P.outline}" stroke-width="10" stroke-linejoin="round" paint-order="stroke"/>`
  )
}

export function tutu(P: Palette, A: string, ctx: DrapeContext, uid: string): string {
  const O = P.outline
  const id = `${uid}tt`
  const light = mix(A, "#ffffff", 0.62)
  const shared = { waist: ring(320, 8), x0: 164, x1: 336, round: true, bell: 5 }
  const back = skirt(ctx, { ...shared, hem: 368, grow: 1.05, scallops: 12, amp: 6.5, drop: 4 })
  const front = skirt(ctx, { ...shared, hem: 364, grow: 1, scallops: 11, amp: 7 })
  return (
    `<defs><clipPath id="${id}"><path d="${front.d}"/></clipPath></defs>` +
    `<path d="${back.d}" fill="${A}" stroke="${O}" stroke-width="11" stroke-linejoin="round" paint-order="stroke"/>` +
    `<path d="${front.d}" fill="${light}"/>` +
    `<g clip-path="url(#${id})">${tutuPleats(front, mix(A, "#ffffff", 0.42))}</g><path d="${front.d}" fill="none" stroke="${O}" stroke-width="3" stroke-linejoin="round"/>` +
    `<defs>${litGradient(`${id}w`, mix(A, "#ffffff", 0.28), mix(A, "#000000", 0.1))}</defs>` +
    `<path d="${tutuBand(ctx)}" fill="url(#${id}w)" stroke="${O}" stroke-width="9" stroke-linejoin="round" paint-order="stroke"/>`
  )
}

export function dressSkirt(P: Palette, A: string, ctx: DrapeContext, uid: string): string {
  const O = P.outline
  const dark = mix(A, "#000000", 0.22)
  const spec = { waist: 346, x0: 166, x1: 334, hem: 392, grow: 1, scallops: 0, amp: 0 }
  const sk = skirt(ctx, spec)
  const trim = skirt(ctx, { ...spec, from: 0.84 })
  return (
    `<defs><linearGradient id="${uid}dr" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".12"/><stop offset="1" stop-color="#000" stop-opacity=".16"/></linearGradient></defs>` +
    `<path d="${sk.d}" fill="${A}" stroke="${O}" stroke-width="11" stroke-linejoin="round" paint-order="stroke"/><path d="${sk.d}" fill="url(#${uid}dr)"/>` +
    dressFolds(P, sk) +
    `<path d="${trim.d}" fill="${CREAM}" stroke="${O}" stroke-width="4" stroke-linejoin="round"/>` +
    `<path d="${dressRibbon(ctx)}" fill="${dark}" stroke="${O}" stroke-width="6" stroke-linejoin="round" paint-order="stroke"/>` +
    dressBow(P, ctx, dark)
  )
}

export function robe(P: Palette, A: string, ctx: DrapeContext, uid: string): string {
  const O = P.outline
  const spec = {
    waist: shouldered(ctx.body, ring(318, 6)),
    x0: 162,
    x1: 338,
    hem: 408,
    grow: 1,
    scallops: 0,
    amp: 0,
    bell: 3
  }
  const sk = skirt(ctx, spec)
  const trim = skirt(ctx, { ...spec, from: 0.91 })
  const at = robePoint(sk)
  const stars = ROBE_STARS.map(([u, v, r, rot]) => {
    const [x, y] = at(u, v)
    return star5(P, x, y, r, "#F5C842", rot)
  }).join("")
  return (
    robeLight(sk, uid) +
    `<path d="${sk.d}" fill="${A}" stroke="${O}" stroke-width="11" stroke-linejoin="round" paint-order="stroke"/>` +
    robeFolds(P, at) +
    stars +
    `<path d="${robeBand(at, 0.49, 0.555)}" fill="${mix(A, "#000000", 0.25)}" stroke="${O}" stroke-width="3.5" stroke-linejoin="round"/>` +
    `<path d="${trim.d}" fill="${GOLD}" stroke="${O}" stroke-width="4" stroke-linejoin="round"/>` +
    `<path d="${sk.d}" fill="url(#${uid}sl)"/>` +
    `<path d="${robeCollar(at)}" fill="${GOLD}" stroke="${O}" stroke-width="4" stroke-linejoin="round"/>`
  )
}

type SkirtPoints = ReturnType<typeof skirt>

function tutuPleats(front: SkirtPoints, pleat: string): string {
  let pleats = ""
  for (let i = 0; i < 12; i += 2) {
    const u0 = i / 12
    const u1 = (i + 1) / 12
    const quad = [
      front.waistAt(u0),
      front.waistAt(u1),
      front.hemAt(u1 + 0.004),
      front.hemAt(u0 - 0.004)
    ]
    const pts = quad.map((p, k): Point => (k > 1 ? [p[0], p[1] + 8] : p))
    pleats += `<path d="${polylineD(pts)}" fill="${pleat}" fill-opacity=".85"/>`
  }
  return pleats
}

function tutuBand(ctx: DrapeContext): string {
  const xs: Array<number> = []
  for (let x = 158; x <= 342; x += 6) xs.push(x)
  const top = ring(311, 8)
  const bot = ring(322, 8)
  const at = (x: number, y: number): Point => anchorAt(ctx.body, ctx.pose, [x, y])
  return polylineD([...xs.map((x) => at(x, top(x))), ...xs.toReversed().map((x) => at(x, bot(x)))])
}

function dressFolds(P: Palette, sk: SkirtPoints): string {
  let folds = ""
  for (const u of [0.25, 0.5, 0.75]) {
    const a = sk.waistAt(u)
    const b = sk.hemAt(u)
    folds += `<path d="M${f2(a[0])} ${f2(a[1] + 8)}L${f2(b[0])} ${f2(b[1] - 9)}" stroke="${P.outline}" stroke-opacity=".28" stroke-width="3" stroke-linecap="round"/>`
  }
  return folds
}

function dressRibbon(ctx: DrapeContext): string {
  const at = (x: number, y: number): Point => anchorAt(ctx.body, ctx.pose, [x, y])
  const xs = [164, 200, 250, 300, 336]
  return polylineD([...xs.map((x) => at(x, 341)), ...xs.toReversed().map((x) => at(x, 350))])
}

function dressBow(P: Palette, ctx: DrapeContext, dark: string): string {
  const [bx, by] = anchorAt(ctx.body, ctx.pose, [250, 345.5])
  const O = P.outline
  return (
    `<path d="M${f2(bx)} ${f2(by)}L${f2(bx - 13)} ${f2(by - 7)}L${f2(bx - 13)} ${f2(by + 7)}ZM${f2(bx)} ${f2(by)}L${f2(bx + 13)} ${f2(by - 7)}L${f2(bx + 13)} ${f2(by + 7)}Z" fill="${dark}" stroke="${O}" stroke-width="7" stroke-linejoin="round" paint-order="stroke"/>` +
    `<circle cx="${f2(bx)}" cy="${f2(by)}" r="4.5" fill="${dark}" stroke="${O}" stroke-width="3"/>`
  )
}

function robePoint(sk: SkirtPoints): (u: number, v: number) => Point {
  return (u, v) => {
    const a = sk.waistAt(u)
    const b = sk.hemAt(u)
    return [a[0] + (b[0] - a[0]) * v, a[1] + (b[1] - a[1]) * v]
  }
}

function robeBand(at: (u: number, v: number) => Point, v0: number, v1: number): string {
  const top: Array<Point> = []
  const bot: Array<Point> = []
  for (let i = 0; i <= 24; i++) {
    top.push(at(i / 24, v0))
    bot.push(at(i / 24, v1))
  }
  return polylineD([...top, ...bot.toReversed()])
}

function robeCollar(at: (u: number, v: number) => Point): string {
  return polylineD([
    at(0, 0),
    at(0.34, 0),
    at(0.5, 0.37),
    at(0.66, 0),
    at(1, 0),
    at(1, 0.08),
    at(0.66, 0.08),
    at(0.5, 0.47),
    at(0.34, 0.085),
    at(0, 0.085)
  ])
}

function robeFolds(P: Palette, at: (u: number, v: number) => Point): string {
  return [0.28, 0.5, 0.72]
    .map((u) => {
      const a = at(u, 0.6)
      const b = at(u, 0.88)
      return `<path d="M${f2(a[0])} ${f2(a[1])}L${f2(b[0])} ${f2(b[1])}" stroke="${P.outline}" stroke-opacity=".22" stroke-width="3" stroke-linecap="round"/>`
    })
    .join("")
}

function robeLight(sk: SkirtPoints, uid: string): string {
  const w0 = sk.waistAt(0)
  const w1 = sk.waistAt(1)
  const h0 = sk.hemAt(0)
  const h1 = sk.hemAt(1)
  const xs = [w0[0], w1[0], h0[0], h1[0]]
  const ys = [w0[1], sk.waistAt(0.5)[1], w1[1], h0[1], sk.hemAt(0.5)[1], h1[1]]
  const bx = Math.min(...xs)
  const bw = Math.max(...xs) - bx
  const by = Math.min(...ys)
  const bh = Math.max(...ys) - by
  return `<defs><linearGradient id="${uid}sl" gradientUnits="userSpaceOnUse" x1="${f2(bx + 0.75 * bw)}" y1="${f2(by)}" x2="${f2(bx + 0.25 * bw)}" y2="${f2(by + bh)}"><stop offset="0" stop-color="#fff" stop-opacity=".1"/><stop offset=".45" stop-color="#fff" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".22"/></linearGradient></defs>`
}
