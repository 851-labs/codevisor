import {
  bodyOf,
  botMascotColors,
  dressed,
  officialBodyZones,
  renderBotMascotFrame,
  renderContext,
  resolveConfig,
  type BotMascotConfig,
  type BotMascotPose
} from "../../src/index.js"
import { collect, defsOf, type Item, type Pt, type Stop } from "./collect.js"
import { IDENTITY, multiply, parseSvg, parseTransform, type El, type Matrix } from "./svg.js"

export const OUT_DIR = new URL("../mascot/", import.meta.url).pathname
export const COLORS = botMascotColors.map((c) => c.id)
export const body = bodyOf(officialBodyZones)
export const RISE = body.rise
export const PIVOT: Pt = [250, 330 - RISE]
export const FEET: Pt = [250, 412]
export const TURNS = [-1, -0.5, 0, 0.5, 1]
export const ROWS = { up: -1, mid: 0, down: 1 } as const
export const TURN_RANGE = 0.8
export const UP_RANGE = 0.55
export const DOWN_RANGE = 0.45
export const TILT_PER_TURN = (4.5 * Math.PI) / 180

export type Face = { turn: number; up: number }
export const pose = (face: Face = { turn: 0, up: 0 }): BotMascotPose => ({
  face: { ...face, blink: 1, mode: "open" }
})

export function render(config: BotMascotConfig, p: BotMascotPose = pose()): El {
  const look = resolveConfig(config)
  const svg = renderBotMascotFrame(renderContext({ idPrefix: "s" }), look.color, dressed(look)(p), {
    viewBox: "0 0 500 500",
    uid: "s"
  })
  return parseSvg(svg)
}

export interface Found {
  el: El
  m: Matrix
}
export function findAll(root: El, pred: (el: El) => boolean, m: Matrix = IDENTITY): Found[] {
  const here = multiply(m, parseTransform(root.attrs.transform))
  const out: Found[] = pred(root) ? [{ el: root, m: here }] : []
  for (const c of root.children) out.push(...findAll(c, pred, here))
  return out
}
export const byRole = (root: El, r: string): Found | undefined =>
  findAll(root, (el) => el.attrs["data-r"] === r)[0]

export const bodyClipped = (items: Item[]): Item[] =>
  items.map((it) => ({ ...it, clips: [{ kind: "body" as const }, ...it.clips] }))

export function deblur(items: Item[]): Item[] {
  return items.map((it) => {
    if (!it.blur || it.geometry.kind !== "ellipse" || it.fill?.kind !== "solid") return it
    const g = it.geometry
    const s = it.blur
    const R = Math.max(g.rx, g.ry) + 2 * s
    const c = it.fill.color
    const alpha = (k: number) =>
      Math.round(parseInt(c.slice(0, 2), 16) * k)
        .toString(16)
        .padStart(2, "0")
        .toUpperCase() + c.slice(2)
    const rx = Math.max(g.rx, g.ry)
    const stops: Stop[] = [
      { offset: 0, color: c },
      { offset: Math.max(0, (rx - 2 * s) / R), color: c },
      { offset: rx / R, color: alpha(0.5) },
      { offset: 1, color: alpha(0) }
    ]
    return {
      ...it,
      blur: 0,
      squash: Math.min(g.rx, g.ry) / Math.max(g.rx, g.ry),
      geometry: {
        ...g,
        rx: R,
        ry: R,
        rotation: g.rx >= g.ry ? g.rotation : g.rotation + Math.PI / 2
      },
      fill: { kind: "radial", centre: [g.cx, g.cy], radius: R, stops }
    }
  })
}

export type PartOf = (root: El) => Item[]
export const part =
  (r: string, clipped = false): PartOf =>
  (root) => {
    const found = byRole(root, r)
    if (!found) return []
    const items = deblur(collect(found.el, defsOf(root), found.m))
    return clipped ? bodyClipped(items) : items
  }
export const shadePart: PartOf = (root) => {
  const rect = findAll(
    root,
    (el) => el.tag === "rect" && !!el.attrs.mask && !el.attrs["clip-path"]
  )[0]
  return rect ? bodyClipped(collect(rect.el, defsOf(root), rect.m)) : []
}
export const mainBodyPart: PartOf = (root) => [
  ...part("shadow")(root),
  ...part("body")(root),
  ...shadePart(root)
]

export const noMakeup = { blush: false, freckles: false, lashes: false }
export const s01 = (x: number) => {
  const c = Math.max(0, Math.min(1, x))
  return c * c * (3 - 2 * c)
}
