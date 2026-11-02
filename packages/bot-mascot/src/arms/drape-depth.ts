import type { Palette } from "../color/palette.js"
import type { DrapeArm } from "../drapes/drape-clearance.js"
import { redrape, type Redraped } from "../drapes/redrape.js"
import { f2 } from "../geometry/math.js"
import type { BotMascotPose } from "../pose.js"
import type { RenderContext } from "../render/context.js"
import { svgBody, svgUid } from "../render/svg-parts.js"
import type { ComposedArm, ComposeItem } from "./compose.js"
import { outlinePoly, signedDistance } from "./outline-poly.js"
import { rootRadius, spinePoints, type ArmSleeve, type RigArm } from "./rig-arm.js"

export interface DrapeAside {
  readonly svg: string
  readonly drape: Redraped | null
}

const DRAPE_GROUP = /(<g data-r="drape">)[^]*?(<\/g><g clip-path="url\(#[^"]+c\)"><g data-r="ewt")/
const BIG = 'x="-200" y="-200" width="900" height="900"'

export function drapeAside(
  ctx: RenderContext,
  svg: string,
  items: ReadonlyArray<ComposeItem>,
  P: Palette,
  pose: BotMascotPose | undefined
): DrapeAside {
  if (!pose) return { svg, drape: null }
  const body = svgBody(svg)
  const arms = items.map((it) => drapeArm(body, it.side, it.arm))
  const drape = redrape({ body: ctx.body, P, pose, uid: svgUid(svg) }, arms, ctx.swings, ctx.now)
  if (!drape) return { svg, drape }
  let s = svg
  const moved = drape.svg
  if (moved != null) s = s.replace(DRAPE_GROUP, (_m, x: string, y: string) => x + moved + y)
  for (const pc of drape.pieces)
    if (pc.hidden) s = s.replace(`<g id="${pc.id}">`, `<g id="${pc.id}" display="none">`)
  return { svg: s, drape }
}

export function overRootCopies(
  svg: string,
  items: ReadonlyArray<ComposeItem>,
  out: Readonly<Record<number, ComposedArm>>,
  aside: DrapeAside,
  sleeve: ArmSleeve | undefined,
  uid: string,
  uidS: string
): { svg: string; overRoot: string } {
  const { drape } = aside
  let s = svg
  let overRoot = ""
  let rdefs = ""
  for (const it of items) {
    const arm = out[it.side]
    if (
      it.layer !== "front" ||
      !arm ||
      !drape ||
      !drape.pieces.length ||
      !drape.over[it.side] ||
      sleeve
    )
      continue
    const id = `${uid}${it.side > 0 ? "r" : "l"}rt`
    if (!s.includes(`id="${uidS}drp"`))
      s = s.replace('<g data-r="drape">', `<g data-r="drape" id="${uidS}drp">`)
    rdefs += rootMask(id, it.arm, arm)
    const hasBand = s.includes(`id="${uidS}dsf"`)
    if (hasBand && !rdefs.includes(`id="${uidS}dsm"`)) rdefs += bandMask(uidS)
    overRoot += pieceCopies(s, id, drape, hasBand ? ` mask="url(#${uidS}dsm)"` : "", uidS)
  }
  if (rdefs) s = s.replace("</defs>", `${rdefs}</defs>`)
  return { svg: s, overRoot }
}

function drapeArm(body: string, side: number, a: RigArm): DrapeArm {
  const rr = rootRadius(a)
  const w = 14 * Math.max(0.3, Math.min(1, a.scale ?? 1))
  const pts = spinePoints(a).map((p) => {
    const root = Math.hypot(p[0] - a.R[0], p[1] - a.R[1]) <= rr
    return { p, w: root ? w * 2.2 : w, root }
  })
  return {
    key: side,
    R: a.R,
    pts,
    tipOut: signedDistance(outlinePoly(body), pts[pts.length - 1]!.p).d
  }
}

function rootMask(id: string, rig: RigArm, arm: ComposedArm): string {
  const Rr = rig.R
  const r = Math.max(rootRadius(rig), (arm.d.rootReach || 0) + 12)
  const shapes = arm.d.shapes
    .map(
      (d) => `<path d="${d}" fill="#fff" stroke="#fff" stroke-width="18" stroke-linejoin="round"/>`
    )
    .join("")
  return (
    `<clipPath id="${id}c"><circle cx="${f2(Rr[0])}" cy="${f2(Rr[1])}" r="${f2(r)}"/></clipPath>` +
    `<mask id="${id}" maskUnits="userSpaceOnUse" ${BIG}><g clip-path="url(#${id}c)">${shapes}</g></mask>`
  )
}

function bandMask(uidS: string): string {
  return `<mask id="${uidS}dsm" maskUnits="userSpaceOnUse" ${BIG}><rect ${BIG} fill="#fff"/><use href="#${uidS}dsf" fill="#000" stroke="#000" stroke-width="12" stroke-linejoin="round"/></mask>`
}

function pieceCopies(s: string, id: string, drape: Redraped, band: string, uidS: string): string {
  const bandAt = s.indexOf(`id="${uidS}dsf"`)
  const ids = drape.pieces
    .map((pc) => pc.id)
    .toSorted((a, b) => s.indexOf(`id="${a}"`) - s.indexOf(`id="${b}"`))
  const uses = ids.map((d) =>
    band && s.indexOf(`id="${d}"`) < bandAt
      ? `<g${band}><use href="#${d}"/></g>`
      : `<use href="#${d}"/>`
  )
  return `<g mask="url(#${id})">${uses.join("")}</g>`
}
