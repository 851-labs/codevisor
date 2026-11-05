import {
  apply,
  IDENTITY,
  multiply,
  parseTransform,
  pathContours,
  rectContour,
  transformContour,
  type Contour,
  type El,
  type Matrix
} from "./svg.js"

export type Pt = [number, number]

export interface Stop {
  offset: number
  color: string
}

export type Paint =
  | { kind: "solid"; color: string }
  | { kind: "linear"; start: Pt; end: Pt; stops: Stop[] }
  | { kind: "radial"; centre: Pt; radius: number; stops: Stop[] }

export interface Stroke {
  paint: Paint
  width: number
  cap: string
  join: string
  dash: number[] | null
}

export type Geometry =
  | { kind: "path"; contours: Contour[] }
  | { kind: "ellipse"; cx: number; cy: number; rx: number; ry: number; rotation: number }

export interface Item {
  geometry: Geometry
  fill: Paint | null
  fillRule: "nonZero" | "evenOdd"
  stroke: Stroke | null
  strokeFirst: boolean
  opacity: number
  clips: ClipRef[]
  hole: Contour[] | null
  blur: number
  squash?: number
}

export type ClipRef = { kind: "body" } | { kind: "local"; key: string; items: Geometry[] }

export interface Defs {
  byId: Map<string, El>
}

export function defsOf(root: El): Defs {
  const byId = new Map<string, El>()
  const visit = (el: El) => {
    if (el.attrs.id) byId.set(el.attrs.id, el)
    el.children.forEach(visit)
  }
  visit(root)
  return { byId }
}

const SKIP = new Set([
  "defs",
  "clipPath",
  "mask",
  "filter",
  "linearGradient",
  "radialGradient",
  "stop"
])
const isBodyClip = (clip: El): boolean => clip.children.some((c) => c.attrs["data-r"] === "clip")

export function collect(root: El, defs: Defs, m: Matrix = IDENTITY): Item[] {
  const out: Item[] = []
  walk(root, defs, m, 1, [], out, true)
  return out
}

function walk(
  el: El,
  defs: Defs,
  parent: Matrix,
  opacity: number,
  clips: ClipRef[],
  out: Item[],
  isRoot: boolean
): void {
  if (SKIP.has(el.tag)) return
  const m = isRoot ? parent : multiply(parent, parseTransform(el.attrs.transform))
  const op = opacity * Number(el.attrs.opacity ?? 1)
  const myClips = [...clips, ...clipOf(el, defs, m)]
  if (el.tag === "g" || el.tag === "#root" || el.tag === "svg") {
    for (const c of el.children) walk(c, defs, m, op, myClips, out, false)
    return
  }
  const geometry = geometryOf(el, m)
  if (!geometry) return
  out.push({
    geometry,
    fill: paintOf(el.attrs.fill ?? "#000", Number(el.attrs["fill-opacity"] ?? 1), el, m, defs),
    fillRule: el.attrs["fill-rule"] === "evenodd" ? "evenOdd" : "nonZero",
    stroke: strokeOf(el, m, defs),
    strokeFirst: el.attrs["paint-order"] === "stroke",
    opacity: op,
    clips: myClips,
    hole: holeOf(el, defs),
    blur: blurOf(el, defs)
  })
}

function clipOf(el: El, defs: Defs, m: Matrix): ClipRef[] {
  const url = /url\(#([^)]+)\)/.exec(el.attrs["clip-path"] ?? "")
  if (!url) return []
  const clip = defs.byId.get(url[1])
  if (!clip) return []
  if (isBodyClip(clip)) return [{ kind: "body" }]
  const items = clip.children
    .map((c) => geometryOf(c, multiply(m, parseTransform(c.attrs.transform))))
    .filter((g): g is Geometry => g !== null)
  return [{ kind: "local", key: url[1], items }]
}

export function geometryOf(el: El, m: Matrix): Geometry | null {
  const a = (k: string) => Number(el.attrs[k] ?? 0)
  if (el.tag === "circle" || el.tag === "ellipse") {
    const rx = el.tag === "circle" ? a("r") : a("rx")
    const ry = el.tag === "circle" ? a("r") : a("ry")
    const [cx, cy] = apply(m, [a("cx"), a("cy")])
    const sx = Math.hypot(m[0], m[1])
    const sy = Math.hypot(m[2], m[3])
    const rotation = Math.atan2(m[1], m[0])
    return { kind: "ellipse", cx, cy, rx: rx * sx, ry: ry * sy, rotation }
  }
  let local: Contour[] | null = null
  if (el.tag === "path") local = pathContours(el.attrs.d)
  if (el.tag === "rect")
    local = [rectContour(a("x"), a("y"), a("width"), a("height"), a("rx") || a("ry"))]
  if (!local) return null
  return { kind: "path", contours: local.map((c) => transformContour(m, c)) }
}

function bboxOfLocal(el: El): [number, number, number, number] {
  const a = (k: string) => Number(el.attrs[k] ?? 0)
  if (el.tag === "circle")
    return [a("cx") - a("r"), a("cy") - a("r"), a("cx") + a("r"), a("cy") + a("r")]
  if (el.tag === "ellipse")
    return [a("cx") - a("rx"), a("cy") - a("ry"), a("cx") + a("rx"), a("cy") + a("ry")]
  if (el.tag === "rect") return [a("x"), a("y"), a("x") + a("width"), a("y") + a("height")]
  const cs = pathContours(el.attrs.d)
  const xs = cs.flatMap((c) => c.vertices.map((v) => v.p[0]))
  const ys = cs.flatMap((c) => c.vertices.map((v) => v.p[1]))
  return [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)]
}

function stopsOf(g: El): Stop[] {
  return g.children
    .filter((s) => s.tag === "stop")
    .map((s) => ({
      offset: Number(s.attrs.offset ?? 0),
      color: withAlpha(s.attrs["stop-color"], Number(s.attrs["stop-opacity"] ?? 1))
    }))
}

function paintOf(value: string, alpha: number, el: El, m: Matrix, defs: Defs): Paint | null {
  if (value === "none") return null
  const url = /url\(#([^)]+)\)/.exec(value)
  if (!url) return { kind: "solid", color: withAlpha(value, alpha) }
  const g = defs.byId.get(url[1])
  if (!g) return null
  const user = g.attrs.gradientUnits === "userSpaceOnUse"
  const [x0, y0, x1, y1] = bboxOfLocal(el)
  const at = (u: number, v: number): Pt =>
    user ? [u, v] : [x0 + u * (x1 - x0), y0 + v * (y1 - y0)]
  const n = (k: string, d: number) => (g.attrs[k] === undefined ? d : Number(g.attrs[k]))
  const stops = stopsOf(g).map((s) => ({ ...s, color: scaleAlpha(s.color, alpha) }))
  if (g.tag === "radialGradient") {
    const c = apply(m, at(n("cx", 0.5), n("cy", 0.5)))
    const r = n("r", 0.5) * (user ? 1 : (x1 - x0 + (y1 - y0)) / 2) * Math.hypot(m[0], m[1])
    return { kind: "radial", centre: c, radius: r, stops }
  }
  return {
    kind: "linear",
    start: apply(m, at(n("x1", 0), n("y1", 0))),
    end: apply(m, at(n("x2", 1), n("y2", 0))),
    stops
  }
}

function strokeOf(el: El, m: Matrix, defs: Defs): Stroke | null {
  const s = el.attrs.stroke
  if (!s || s === "none") return null
  const paint = paintOf(s, Number(el.attrs["stroke-opacity"] ?? 1), el, m, defs)
  if (!paint) return null
  const scale = Math.sqrt(Math.abs(m[0] * m[3] - m[1] * m[2]))
  const dash =
    el.attrs["stroke-dasharray"]
      ?.split(/[\s,]+/)
      .filter(Boolean)
      .map((v) => Number(v) * scale) ?? null
  return {
    paint,
    width: Number(el.attrs["stroke-width"] ?? 1) * scale,
    cap: el.attrs["stroke-linecap"] ?? "butt",
    join: el.attrs["stroke-linejoin"] ?? "miter",
    dash
  }
}

function holeOf(el: El, defs: Defs): Contour[] | null {
  const url = /url\(#([^)]+)\)/.exec(el.attrs.mask ?? "")
  if (!url) return null
  const mask = defs.byId.get(url[1])
  const black = mask?.children.find((c) => c.tag === "path")
  if (!black) return null
  return pathContours(black.attrs.d).map((c) =>
    transformContour(parseTransform(black.attrs.transform), c)
  )
}

function blurOf(el: El, defs: Defs): number {
  const url = /url\(#([^)]+)\)/.exec(el.attrs.filter ?? "")
  if (!url) return 0
  const blur = defs.byId.get(url[1])?.children.find((c) => c.tag === "feGaussianBlur")
  return Number(blur?.attrs.stdDeviation ?? 0)
}

const hexByte = (v: number) => Math.round(v).toString(16).padStart(2, "0").toUpperCase()

export function withAlpha(color: string, alpha: number): string {
  const rgba = /rgba?\(([^)]+)\)/.exec(color)
  let r: number, g: number, b: number, a: number
  if (rgba) {
    const v = rgba[1].split(",").map(Number)
    ;[r, g, b] = [v[0], v[1], v[2]]
    a = (v[3] ?? 1) * alpha
  } else {
    const hex = color.replace("#", "")
    const full =
      hex.length === 3
        ? hex
            .split("")
            .map((c) => c + c)
            .join("")
        : hex
    r = parseInt(full.slice(0, 2), 16)
    g = parseInt(full.slice(2, 4), 16)
    b = parseInt(full.slice(4, 6), 16)
    a = alpha
  }
  return `${hexByte(Math.max(0, Math.min(1, a)) * 255)}${hexByte(r)}${hexByte(g)}${hexByte(b)}`
}

export function scaleAlpha(argb: string, k: number): string {
  if (k >= 0.9999) return argb
  const a = Math.round(parseInt(argb.slice(0, 2), 16) * k)
  return a.toString(16).padStart(2, "0").toUpperCase() + argb.slice(2)
}

export function paintsOf(items: Item[]): string[] {
  const out: string[] = []
  const add = (p: Paint | null) => {
    if (!p) return
    if (p.kind === "solid") out.push(p.color)
    else for (const s of p.stops) out.push(s.color)
  }
  for (const it of items) {
    add(it.fill)
    add(it.stroke?.paint ?? null)
  }
  return out
}

export function centreOf(g: Geometry): Pt {
  if (g.kind === "ellipse") return [g.cx, g.cy]
  const vs = g.contours.flatMap((c) => c.vertices)
  return [
    vs.reduce((s, v) => s + v.p[0], 0) / vs.length,
    vs.reduce((s, v) => s + v.p[1], 0) / vs.length
  ]
}
