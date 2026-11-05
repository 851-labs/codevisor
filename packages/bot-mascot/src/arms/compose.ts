import { palette, type Palette } from "../color/palette.js"
import { f2, type Point } from "../geometry/math.js"
import type { BotMascotPose } from "../pose.js"
import type { RenderContext } from "../render/context.js"
import { svgBody, svgGradientId, svgSleeve, svgTransform, svgUid } from "../render/svg-parts.js"
import { armLine } from "./arm-lines.js"
import {
  armPolygon,
  mouthMid,
  silhouette,
  snapToOutline,
  type Silhouette
} from "./arm-silhouette.js"
import {
  difference,
  intersection,
  offset,
  pathsD,
  simplified,
  union,
  type ClipPaths
} from "./clip.js"
import { drapeAside, overRootCopies } from "./drape-depth.js"
import { drawArm, handEmergence, type ArmDrawing } from "./draw-arm.js"
import { densePoly } from "./outline-poly.js"
import { handOverGrip, SMALLEST_HAND } from "./prop-hand.js"
import type { ArmSleeve, RigArm } from "./rig-arm.js"

export type ArmLayer = "body" | "behind" | "between" | "front"

export interface ComposeItem {
  readonly side: number
  readonly arm: RigArm
  readonly layer: ArmLayer
  readonly shade?: boolean
  readonly frontClip?: string | undefined
  readonly over?: number | undefined
}

export interface BetweenLayer {
  readonly at: RegExp
  readonly transform: string
}

export interface ComposeOptions {
  readonly uid: string
  readonly pal: string
  readonly blush?: number
  readonly between?: BetweenLayer
  readonly pose?: BotMascotPose
}

export interface ComposedArm {
  readonly tip: Point
  readonly top: Point
  readonly fill: string
  readonly arm: RigArm
  readonly layer: ArmLayer
  readonly d: ArmDrawing
}

export interface Composed {
  readonly svg: string
  readonly arms: Readonly<Record<number, ComposedArm>>
  readonly tops: Readonly<Record<number, string>>
}

interface Art {
  readonly it: ComposeItem
  readonly id: string
  readonly d: ArmDrawing
  readonly ring: ReadonlyArray<Point>
  readonly polygon: ClipPaths
}

interface Layers {
  defs: string
  inBody: string
  front: string
  between: string
  behind: string
}

export function compose(
  ctx: RenderContext,
  svg: string,
  items: ReadonlyArray<ComposeItem>,
  opts: ComposeOptions
): Composed {
  const P = palette(opts.pal)
  const body = svgBody(svg)
  const grad = svgGradientId(svg)
  const aside = drapeAside(ctx, svg, items, P, opts.pose)
  let s = aside.svg
  const sleeve = parseSleeve(svgSleeve(s))
  const drawn = items.map((it) => drawItem(body, it, sleeve, P, grad, opts.uid))
  const poly = densePoly(
    body,
    drawn.map(({ d }) => [...mouthMid(d), 110] as const)
  )
  const arts = drawn.map((x): Art => {
    const pts = snapToOutline(body, poly, x.d.poly, mouthMid(x.d))
    return { ...x, ring: pts.slice(0, x.d.ring.length), polygon: armPolygon(pts) }
  })
  const sil = silhouette(
    poly,
    arts.map((x) => x.polygon),
    arts.map((x) => mouthMid(x.d)),
    !!sleeve
  )
  const layers: Layers = {
    defs: arts.map((x) => x.d.defs).join(""),
    inBody: "",
    front: "",
    between: "",
    behind: ""
  }
  const joined = unionPaths(body, sil, layers, P, grad, sleeve, arts, opts.uid)
  const tops: Record<number, string> = {}
  for (const art of arts) {
    const own = armArt(art, arts, sil, poly, P, grad, sleeve, s, svgUid(svg))
    const copied = placeArm(layers, art, own)
    if (copied && art.it.over) {
      const size = art.it.over * handEmergence(poly, art.it.arm)
      if (size > SMALLEST_HAND) tops[art.it.side] = handOverGrip(art.it.arm, P, grad, size)
    }
  }
  if (joined) s = replaceBody(s, joined)
  s = withArmsInBody(s, layers.inBody, P, svgUid(svg))
  s = withBlushKeptOff(s, layers, arts, opts)
  s = s.replace("</defs>", `${layers.defs}</defs>`)
  const tf = svgTransform(svg)
  if (layers.between && opts.between) {
    s = s.replace(
      opts.between.at,
      `$1<g transform="${opts.between.transform}"><g transform="${tf}">${layers.between}</g></g>`
    )
  }
  const out = Object.fromEntries(arts.map(({ it, d }) => [it.side, composedArm(it, d)]))
  const over = overRootCopies(s, items, out, aside, sleeve, opts.uid, svgUid(svg))
  s = over.svg
  if (layers.behind)
    s = s.replace('<g data-r="fx">', `<g transform="${tf}">${layers.behind}</g><g data-r="fx">`)
  if (layers.front)
    s = s.replace(/<\/svg>$/, `<g transform="${tf}">${layers.front}${over.overRoot}</g></svg>`)
  return { svg: s, arms: out, tops }
}

function parseSleeve(sl: string | undefined): ArmSleeve | undefined {
  if (!sl) return undefined
  const [c = "", len = "", cuff = "", op = ""] = sl.split("|")
  return { c, len: +len, cuff, op: +op }
}

function drawItem(
  body: string,
  it: ComposeItem,
  sleeve: ArmSleeve | undefined,
  P: Palette,
  grad: string,
  uid: string
): { it: ComposeItem; id: string; d: ArmDrawing } {
  const id = `${uid}${it.side > 0 ? "r" : "l"}`
  const arm = sleeve ? { ...it.arm, sleeve } : it.arm
  return { it, id, d: drawArm(body, arm, it.side, P, grad, id, it.shade ?? it.side < 0) }
}

const composedArm = (it: ComposeItem, d: ArmDrawing): ComposedArm => ({
  tip: d.tip,
  top: d.topStart,
  fill: d.fill,
  arm: it.arm,
  layer: it.layer,
  d
})

function armArt(
  art: Art,
  arts: ReadonlyArray<Art>,
  sil: Silhouette,
  poly: ReadonlyArray<Point>,
  P: Palette,
  grad: string,
  sleeve: ArmSleeve | undefined,
  s: string,
  uidS: string
): string {
  const { d } = art
  const line = armLine(
    { poly, keep: sil.keep, inShape: sil.inShape, armPolys: arts.map((x) => x.polygon) },
    art.ring,
    d.ends
  )
  const solid = `<path d="${pathsD(art.polygon)}" fill="url(#${grad})"/>` + d.art
  const { patch, light } = sleevePatch(art, sil, sleeve, s, uidS)
  const outline = line
    ? `<path d="${line}" fill="none" stroke="${P.outline}" stroke-width="16" stroke-linejoin="round" stroke-linecap="round"/>`
    : ""
  return (
    outline +
    solid.replace(d.art, "") +
    patch +
    (patch ? d.art.replace(/^<path [^>]*\/>/, "") : d.art) +
    light
  )
}

function sleevePatch(
  art: Art,
  sil: Silhouette,
  sleeve: ArmSleeve | undefined,
  s: string,
  uidS: string
): { patch: string; light: string } {
  const slv = art.d.slv
  if (!sleeve || !slv) return { patch: "", light: "" }
  const zone = offset(simplified(slv), 2.5)
  const cloth = union(
    intersection(union(art.polygon, sil.added), zone),
    difference(sil.added, art.polygon)
  )
  const opacity = sleeve.op < 0.999 ? ` opacity="${f2(sleeve.op)}"` : ""
  const patch = cloth.length ? `<path d="${pathsD(cloth)}" fill="${sleeve.c}"${opacity}/>` : ""
  if (!s.includes(`id="${uidS}sl"`)) return { patch, light: "" }
  const all = union(cloth, simplified(slv))
  return { patch, light: `<path d="${pathsD(all)}" fill="url(#${uidS}sl)"/>` }
}

function placeArm(layers: Layers, art: Art, own: string): boolean {
  const { it, id } = art
  layers.inBody += own
  if (it.layer === "body") return false
  if (it.layer === "behind") {
    layers.behind += own
    return false
  }
  let copy = own
  if (it.frontClip) {
    layers.defs += `<clipPath id="${id}fk"><path d="${it.frontClip}"/></clipPath>`
    copy = `<g clip-path="url(#${id}fk)">${copy}</g>`
  }
  if (it.layer === "front") layers.front += copy
  else layers.between += copy
  return true
}

function unionPaths(
  body: string,
  sil: Silhouette,
  layers: Layers,
  P: Palette,
  grad: string,
  sleeve: ArmSleeve | undefined,
  arts: ReadonlyArray<Art>,
  uid: string
): string {
  if (!sil.shape.length) return ""
  const shapeD = pathsD(sil.shape)
  const joined = `<path data-r="outline" d="${shapeD}" fill="url(#${grad})" stroke="${P.outline}" stroke-width="16" stroke-linejoin="round" paint-order="stroke"/>`
  if (!sleeve) return joined
  const md = `${uid}fm`
  const fillets = arts.map(({ d }) => armpitFillet(d)).join("")
  layers.defs += `<mask id="${md}" maskUnits="userSpaceOnUse" x="-200" y="-200" width="900" height="900">${fillets}<path d="${body}" fill="#000"/></mask>`
  const opacity = sleeve.op < 0.999 ? ` opacity="${f2(sleeve.op)}"` : ""
  return joined + `<path d="${shapeD}" fill="${sleeve.c}"${opacity} mask="url(#${md})"/>`
}

function replaceBody(s: string, joined: string): string {
  return s.replace(
    /<path data-r="body" d="([^"]+)" fill="([^"]+)" stroke="[^"]+" stroke-width="16" stroke-linejoin="round" paint-order="stroke"\/>/,
    (_m, dd: string, fl: string) => `<path data-r="body" d="${dd}" fill="${fl}"/>${joined}`
  )
}

function armpitFillet(d: ArmDrawing): string {
  const [eT, eB] = d.ends
  const mo = mouthMid(d)
  const r = Math.hypot(eT[0] - eB[0], eT[1] - eB[1]) / 2 + 18
  return `<circle cx="${f2(mo[0])}" cy="${f2(mo[1])}" r="${f2(r)}" fill="#fff"/>`
}

function withArmsInBody(s: string, inBody: string, P: Palette, uidS: string): string {
  const shadePass = `<g clip-path="url(#${uidS}c)"><rect x="40" y="20" width="420" height="460" fill="${P.shade}" mask="url(#${uidS}m)"/></g>`
  if (s.includes(shadePass)) return s.replace(shadePass, () => shadePass + inBody)
  return s.replace(/<path data-r="body"[^>]*\/>/, (m) => m + inBody)
}

function withBlushKeptOff(
  s: string,
  layers: Layers,
  arts: ReadonlyArray<Art>,
  opts: ComposeOptions
): string {
  const { uid } = opts
  const bl = opts.blush ?? 1
  const fills = arts
    .map(
      ({ d }) =>
        `<path d="${d.fill}" fill="#000" stroke="#000" stroke-width="34" stroke-linejoin="round" opacity="${f2(bl)}"/>`
    )
    .join("")
  layers.defs +=
    `<filter id="${uid}bf" filterUnits="userSpaceOnUse" x="-100" y="-100" width="700" height="700"><feGaussianBlur stdDeviation="5"/></filter>` +
    `<mask id="${uid}bl" maskUnits="userSpaceOnUse" x="-100" y="-100" width="700" height="700"><rect x="-100" y="-100" width="700" height="700" fill="#fff"/><g filter="url(#${uid}bf)">${fills}</g></mask>`
  if (!(bl > 0)) return s
  return s.replace(
    /(<g data-r="mkt"[^>]*><g data-r="makeup">[^]*?<\/g><\/g>)/,
    `<g mask="url(#${uid}bl)">$1</g>`
  )
}
