import type { ClipRef, Geometry, Item, Paint, Pt } from "./collect.js"
import type { Contour, Vertex } from "./svg.js"

let counter = 1000
export const newId = (): string => `0:${++counter}`
export const f = (v: number): string =>
  Math.abs(v) < 1e-6 ? "0" : v.toFixed(4).replace(/\.?0+$/, "")

export interface Skinning {
  readonly tendons: string
  readonly weight: (p: Pt) => number
}

export interface GeometryIds {
  readonly shape: string
  readonly ellipse?: string
  readonly vertices: string[][]
  readonly fillGradient?: string
  readonly strokeGradient?: string
}

export interface EmitOptions {
  readonly bind: (paintIndex: number) => string
  readonly bodyClip?: string
  readonly skin?: Skinning
}

export interface Emitted {
  readonly rml: string
  readonly clipRml: string
  readonly ids: GeometryIds[]
  readonly clipIds: Map<string, GeometryIds[]>
}

export const handle = (v: Vertex, q: Pt | undefined): [number, number] =>
  q ? [Math.atan2(q[1] - v.p[1], q[0] - v.p[0]), Math.hypot(q[0] - v.p[0], q[1] - v.p[1])] : [0, 0]

function weightXml(w: number, cubic: boolean): string {
  const t = Math.round(255 * Math.max(0, Math.min(1, w)))
  const influences: Array<[number, number]> = [
    [1, 255 - t],
    [2, t]
  ]
  const pairs = influences.filter(([, v]) => v > 0)
  let idx = 0
  let val = 0
  pairs.forEach(([i, v], k) => {
    idx |= i << (8 * k)
    val |= v << (8 * k)
  })
  if (!cubic) return `<Weight values="${val >>> 0}" indices="${idx >>> 0}"/>`
  return `<CubicWeight values="${val >>> 0}" indices="${idx >>> 0}" inValues="${val >>> 0}" inIndices="${idx >>> 0}" outValues="${val >>> 0}" outIndices="${idx >>> 0}"/>`
}

export function pointsPath(c: Contour, ids: string[], skin?: Skinning): string {
  const vs = c.vertices.map((v, i) => {
    const vid = ` id="${ids[i]}"`
    const cubic = !!(v.inH || v.outH)
    const w = skin ? weightXml(skin.weight(v.p), cubic) : ""
    if (!cubic)
      return `<StraightVertex x="${f(v.p[0])}" y="${f(v.p[1])}"${vid}>${w}</StraightVertex>`
    const [ir, id_] = handle(v, v.inH)
    const [or, od] = handle(v, v.outH)
    return `<CubicDetachedVertex x="${f(v.p[0])}" y="${f(v.p[1])}" inRotation="${f(ir)}" inDistance="${f(id_)}" outRotation="${f(or)}" outDistance="${f(od)}"${vid}>${w}</CubicDetachedVertex>`
  })
  const skinXml = skin
    ? `<Skin xx="1" xy="0" yx="0" yy="1" tx="0" ty="0" name="Skin">${skin.tendons}</Skin>`
    : ""
  return `<PointsPath isClosed="${c.closed}" name="Path">${vs.join("")}${skinXml}</PointsPath>`
}

const ellipseAsContour = (g: Extract<Geometry, { kind: "ellipse" }>): Contour => {
  const K = 0.5522847498
  const c = Math.cos(g.rotation)
  const s = Math.sin(g.rotation)
  const at = (x: number, y: number): Pt => [g.cx + x * c - y * s, g.cy + x * s + y * c]
  const pts: Array<[number, number, number, number]> = [
    [g.rx, 0, 0, 1],
    [0, g.ry, -1, 0],
    [-g.rx, 0, 0, -1],
    [0, -g.ry, 1, 0]
  ]
  return {
    closed: true,
    vertices: pts.map(([x, y, tx, ty]) => ({
      p: at(x, y),
      inH: at(x - tx * K * g.rx, y - ty * K * g.ry),
      outH: at(x + tx * K * g.rx, y + ty * K * g.ry)
    }))
  }
}

export const asContours = (g: Geometry): Contour[] =>
  g.kind === "path" ? g.contours : [ellipseAsContour(g)]

function geometryXml(
  g: Geometry,
  ids: GeometryIds,
  skin: Skinning | undefined,
  hole: Contour[] | null
): { xml: string; x: number; y: number; rotation: number } {
  if (g.kind === "ellipse" && !skin) {
    return {
      xml: `<Ellipse width="${f(2 * g.rx)}" height="${f(2 * g.ry)}" originX="0.5" originY="0.5" name="E" id="${ids.ellipse}"/>`,
      x: g.cx,
      y: g.cy,
      rotation: g.rotation
    }
  }
  const contours = asContours(g)
  const paths = contours.map((c, i) => pointsPath(c, ids.vertices[i], skin)).join("")
  const holes = (hole ?? [])
    .map((c) =>
      pointsPath(
        c,
        c.vertices.map(() => newId()),
        skin
      )
    )
    .join("")
  return { xml: paths + holes, x: 0, y: 0, rotation: 0 }
}

function paintXml(
  p: Paint,
  bind: (i: number) => string,
  next: () => number,
  gradientId: string | undefined,
  local: Pt
): string {
  if (p.kind === "solid")
    return `<SolidColor colorValue="${p.color}" name="C">${bind(next())}</SolidColor>`
  const stops = p.stops
    .map(
      (s) =>
        `<GradientStop colorValue="${s.color}" position="${f(s.offset)}">${bind(next())}</GradientStop>`
    )
    .join("")
  const gid = gradientId ? ` id="${gradientId}"` : ""
  if (p.kind === "linear") {
    return `<LinearGradient startX="${f(p.start[0] - local[0])}" startY="${f(p.start[1] - local[1])}" endX="${f(p.end[0] - local[0])}" endY="${f(p.end[1] - local[1])}" name="G"${gid}>${stops}</LinearGradient>`
  }
  return `<RadialGradient startX="${f(p.centre[0] - local[0])}" startY="${f(p.centre[1] - local[1])}" endX="${f(p.centre[0] - local[0] + p.radius)}" endY="${f(p.centre[1] - local[1])}" name="G"${gid}>${stops}</RadialGradient>`
}

export function idsFor(
  it: Pick<Item, "geometry"> & Partial<Pick<Item, "fill" | "stroke">>
): GeometryIds {
  const contours = asContours(it.geometry)
  return {
    shape: newId(),
    ellipse: newId(),
    vertices: contours.map((c) => c.vertices.map(() => newId())),
    ...(it.fill && it.fill.kind !== "solid" ? { fillGradient: newId() } : {}),
    ...(it.stroke && it.stroke.paint.kind !== "solid" ? { strokeGradient: newId() } : {})
  }
}

export function emitItems(items: Item[], opts: EmitOptions, presetIds?: GeometryIds[]): Emitted {
  const clipIds = new Map<string, GeometryIds[]>()
  const clipShapes = new Map<string, string>()
  let clipRml = ""
  const clipFor = (c: ClipRef): string => {
    if (c.kind === "body")
      return opts.bodyClip ? `<ClippingShape sourceId="${opts.bodyClip}" name="Body clip"/>` : ""
    if (!clipShapes.has(c.key)) {
      const sid = newId()
      const gids = c.items.map((g) => idsFor({ geometry: g }))
      clipIds.set(c.key, gids)
      clipShapes.set(c.key, sid)
      const inner = c.items
        .map((g, i) => {
          const gx = geometryXml(g, gids[i], opts.skin, null)
          if (g.kind === "ellipse" && !opts.skin)
            return `<Shape x="${f(gx.x)}" y="${f(gx.y)}" rotation="${f(gx.rotation)}" name="Clip part" id="${gids[i].shape}">${gx.xml}</Shape>`
          return gx.xml
        })
        .join("")
      clipRml += `<Shape name="Clip ${c.key}" id="${sid}">${inner}</Shape>`
    }
    return `<ClippingShape sourceId="${clipShapes.get(c.key)}" name="Clip"/>`
  }
  let paintIndex = 0
  const ids: GeometryIds[] = []
  const shapes = items.map((it, i) => {
    const gi = presetIds?.[i] ?? idsFor(it)
    ids.push(gi)
    const gx = geometryXml(it.geometry, gi, opts.skin, it.hole)
    const local: Pt = [gx.x, gx.y]
    const paints: string[] = []
    if (it.fill)
      paints.push(
        `<Fill fillRule="${it.hole ? "evenOdd" : it.fillRule}" name="Fill">${paintXml(it.fill, opts.bind, () => paintIndex++, gi.fillGradient, local)}</Fill>`
      )
    if (it.stroke) {
      const dash = it.stroke.dash?.length
        ? `<DashPath name="Dashes">${it.stroke.dash.map((d) => `<Dash length="${f(d)}" name="D"/>`).join("")}</DashPath>`
        : ""
      const s = `<Stroke thickness="${f(it.stroke.width)}" cap="${it.stroke.cap}" join="${it.stroke.join}" name="Stroke">${paintXml(it.stroke.paint, opts.bind, () => paintIndex++, gi.strokeGradient, local)}${dash}</Stroke>`
      if (it.strokeFirst) paints.unshift(s)
      else paints.push(s)
    }
    const clips = it.clips.map(clipFor).join("")
    const squash = it.squash && !opts.skin ? ` scaleY="${f(it.squash)}"` : ""
    return `<Shape x="${f(gx.x)}" y="${f(gx.y)}" rotation="${f(gx.rotation)}"${squash} opacity="${f(it.opacity)}" name="Part" id="${gi.shape}">${gx.xml}${paints.join("")}${clips}</Shape>`
  })
  return { rml: shapes.toReversed().join("\n"), clipRml, ids, clipIds }
}
