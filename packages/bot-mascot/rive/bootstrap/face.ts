import { botMascotEyewear, type BotMascotConfig } from "../../src/index.js"
import { centreOf, paintsOf, type Geometry, type Item, type Pt } from "./collect.js"
import { planned } from "./colors.js"
import { bindFace, bindFor, faceVm, prop, solo } from "./data.js"
import { asContours, emitItems, f, handle, newId, pointsPath, type GeometryIds } from "./emit.js"
import {
  type Face,
  type PartOf,
  ROWS,
  TURNS,
  body,
  noMakeup,
  part,
  pose,
  render,
  s01
} from "./parts.js"
import { pathContours, type Contour, type El } from "./svg.js"

export interface FacePart {
  readonly name: string
  readonly config: BotMascotConfig
  readonly of: PartOf
  readonly pick?: (items: Item[]) => number[]
  readonly cat: string
  readonly item: string
  readonly relative?: boolean
}

export const faceBodyClip = newId()
export const lashesBase = part("face", true)(render({ makeup: noMakeup })).length
export const withLashes = { makeup: { ...noMakeup, lashes: true } }
export const indices = (items: Item[], keep: (it: Item, i: number) => boolean) =>
  items.flatMap((it, i) => (keep(it, i) ? [i] : []))
export const faceParts: FacePart[] = [
  {
    name: "eye",
    config: withLashes,
    of: part("face", true),
    pick: (it) => indices(it, (x, i) => i < lashesBase && x.geometry.kind === "path"),
    cat: "face",
    item: "face",
    relative: true
  },
  {
    name: "shine",
    config: withLashes,
    of: part("face", true),
    pick: (it) => indices(it, (x, i) => i < lashesBase && x.geometry.kind === "ellipse"),
    cat: "face",
    item: "face",
    relative: true
  },
  {
    name: "lashes",
    config: withLashes,
    of: part("face", true),
    pick: (it) => indices(it, (_, i) => i >= lashesBase),
    cat: "face",
    item: "face",
    relative: true
  },
  {
    name: "blush",
    config: { makeup: { ...noMakeup, blush: true } },
    of: part("makeup", true),
    cat: "blush",
    item: "blush"
  },
  {
    name: "freckles",
    config: { makeup: { ...noMakeup, freckles: true } },
    of: part("makeup", true),
    cat: "freckles",
    item: "freckles"
  },
  ...botMascotEyewear.map((e) => ({
    name: e.id,
    config: { eyewear: e.id, makeup: noMakeup },
    of: part("eyewear", true),
    cat: "eyewear",
    item: e.id
  }))
]

export const shiftPoint = ([x, y]: Pt, d: Pt): Pt => [x - d[0], y - d[1]]
export const shiftContour = (c: Contour, d: Pt): Contour => ({
  closed: c.closed,
  vertices: c.vertices.map((v) => ({
    p: shiftPoint(v.p, d),
    ...(v.inH ? { inH: shiftPoint(v.inH, d) } : {}),
    ...(v.outH ? { outH: shiftPoint(v.outH, d) } : {})
  }))
})
export const shiftGeometry = (g: Geometry, d: Pt): Geometry =>
  g.kind === "ellipse"
    ? { ...g, cx: g.cx - d[0], cy: g.cy - d[1] }
    : { kind: "path", contours: g.contours.map((c) => shiftContour(c, d)) }
export const shiftPaint = (p: Item["fill"], d: Pt): Item["fill"] => {
  if (!p || p.kind === "solid") return p
  if (p.kind === "linear") return { ...p, start: shiftPoint(p.start, d), end: shiftPoint(p.end, d) }
  return { ...p, centre: shiftPoint(p.centre, d) }
}
export const shiftItem = (it: Item, d: Pt): Item => ({
  ...it,
  geometry: shiftGeometry(it.geometry, d),
  fill: shiftPaint(it.fill, d),
  stroke: it.stroke ? { ...it.stroke, paint: shiftPaint(it.stroke.paint, d)! } : null,
  hole: it.hole?.map((c) => shiftContour(c, d)) ?? null,
  clips: it.clips.map((c) =>
    c.kind === "local" ? { ...c, items: c.items.map((g) => shiftGeometry(g, d)) } : c
  )
})

export const plannedAll = (fp: FacePart, root: El): Item[] =>
  planned(`${fp.cat}/${fp.item}`, fp.of)(root)
export const lidCentre = (root: El): Pt => {
  const eye = part("face", true)(root)[0]
  const vs = asContours(eye.geometry).flatMap((c) => c.vertices.map((v) => v.p))
  const xs = vs.map((p) => p[0])
  const ys = vs.map((p) => p[1])
  return [(Math.min(...xs) + Math.max(...xs)) / 2, (Math.min(...ys) + Math.max(...ys)) / 2]
}
export const partItems = (fp: FacePart, root: El): Item[] => {
  const all = plannedAll(fp, root)
  const picked = fp.pick ? fp.pick(all).map((i) => all[i]) : all
  return fp.relative ? picked.map((it) => shiftItem(it, lidCentre(root))) : picked
}
export const bindSubset = (fp: FacePart, root: El): ((i: number) => string) => {
  const all = plannedAll(fp, root)
  const global: number[] = []
  let k = 0
  const chosen = new Set(fp.pick ? fp.pick(all) : all.map((_, i) => i))
  all.forEach((it, i) => {
    const n = paintsOf([it]).length
    if (chosen.has(i)) for (let j = 0; j < n; j++) global.push(k + j)
    k += n
  })
  const bind = bindFor(fp.cat, fp.item)
  return (i) => bind(global[i])
}

export const faceItems = (fp: FacePart, face: Face): Item[] =>
  partItems(fp, render(fp.config, pose(face)))

export interface Built {
  fp: FacePart
  neutral: Item[]
  ids: GeometryIds[]
  clipIds: Map<string, GeometryIds[]>
  xml: string
}
export const builtFace: Built[] = faceParts.map((fp) => {
  const neutral = faceItems(fp, { turn: 0, up: 0 })
  const e = emitItems(neutral, { bind: bindSubset(fp, render(fp.config)), bodyClip: faceBodyClip })
  return { fp, neutral, ids: e.ids, clipIds: e.clipIds, xml: e.rml + e.clipRml }
})

export function unwrap(values: number[], ref: number): number[] {
  return values.map((v) => {
    let x = v
    while (x - ref > Math.PI) x -= 2 * Math.PI
    while (x - ref < -Math.PI) x += 2 * Math.PI
    return x
  })
}

export function match(neutral: Item[], items: Item[]): Array<Item | null> {
  if (items.length === neutral.length) return items
  const used = new Set<number>()
  return neutral.map((n) => {
    const c = centreOf(n.geometry)
    let best = -1
    let bestD = Infinity
    items.forEach((it, i) => {
      if (used.has(i) || it.geometry.kind !== n.geometry.kind) return
      const d = Math.hypot(centreOf(it.geometry)[0] - c[0], centreOf(it.geometry)[1] - c[1])
      if (d < bestD) {
        bestD = d
        best = i
      }
    })
    if (best < 0 || bestD > 60) return null
    used.add(best)
    return items[best]
  })
}

const bareItem = (geometry: Geometry): Item => ({
  geometry,
  fill: null,
  fillRule: "nonZero",
  stroke: null,
  strokeFirst: false,
  opacity: 1,
  clips: [],
  hole: null,
  blur: 0
})

export type Track = Map<string, Map<string, Array<[number, number]>>>
export const addKey = (
  tracks: Track,
  obj: string,
  property: string,
  frame: number,
  value: number
) => {
  if (!tracks.has(obj)) tracks.set(obj, new Map())
  const t = tracks.get(obj)!
  if (!t.has(property)) t.set(property, [])
  t.get(property)!.push([frame, value])
}

export function keyItem(
  tracks: Track,
  ids: GeometryIds,
  it: Item | null,
  fallback: Item,
  frame: number,
  withShape = true
) {
  const src = it ?? fallback
  if (withShape) addKey(tracks, ids.shape, "opacity", frame, it ? src.opacity : 0)
  const g = src.geometry
  if (g.kind === "ellipse") {
    if (src.squash) addKey(tracks, ids.shape, "scaleY", frame, src.squash)
    addKey(tracks, ids.shape, "x", frame, g.cx)
    addKey(tracks, ids.shape, "y", frame, g.cy)
    addKey(tracks, ids.shape, "rotation", frame, g.rotation)
    addKey(tracks, ids.ellipse!, "width", frame, 2 * g.rx)
    addKey(tracks, ids.ellipse!, "height", frame, 2 * g.ry)
  } else {
    asContours(g).forEach((c, ci) =>
      c.vertices.forEach((v, vi) => {
        const vid = ids.vertices[ci]?.[vi]
        if (!vid) return
        addKey(tracks, vid, "x", frame, v.p[0])
        addKey(tracks, vid, "y", frame, v.p[1])
        if (v.inH || v.outH) {
          const [ir, id_] = handle(v, v.inH)
          const [or, od] = handle(v, v.outH)
          addKey(tracks, vid, "inRotation", frame, ir)
          addKey(tracks, vid, "inDistance", frame, id_)
          addKey(tracks, vid, "outRotation", frame, or)
          addKey(tracks, vid, "outDistance", frame, od)
        }
      })
    )
  }
  const grad = (gid: string | undefined, p: Item["fill"]) => {
    if (!gid || !p || p.kind === "solid") return
    const local: Pt = g.kind === "ellipse" ? [g.cx, g.cy] : [0, 0]
    const s = p.kind === "linear" ? p.start : p.centre
    const e = p.kind === "linear" ? p.end : ([p.centre[0] + p.radius, p.centre[1]] as Pt)
    addKey(tracks, gid, "startX", frame, s[0] - local[0])
    addKey(tracks, gid, "startY", frame, s[1] - local[1])
    addKey(tracks, gid, "endX", frame, e[0] - local[0])
    addKey(tracks, gid, "endY", frame, e[1] - local[1])
  }
  grad(ids.fillGradient, src.fill)
  grad(ids.strokeGradient, src.stroke?.paint ?? null)
}

export function keyClips(tracks: Track, b: Built, root: El, frame: number) {
  const sliced = partItems(b.fp, root)
  const done = new Set<string>()
  const neutralKeys = [...b.clipIds.keys()]
  const poseKeys: string[] = []
  for (const it of sliced)
    for (const c of it.clips)
      if (c.kind === "local" && !poseKeys.includes(c.key)) poseKeys.push(c.key)
  for (const it of sliced) {
    for (const c of it.clips) {
      if (c.kind !== "local") continue
      const key = neutralKeys[poseKeys.indexOf(c.key)]
      const gids = key === undefined ? undefined : b.clipIds.get(key)
      if (!gids || done.has(key)) continue
      done.add(key)
      c.items.forEach((g, i) => {
        if (!gids[i]) return
        const fake = bareItem(g)
        keyItem(tracks, gids[i], fake, fake, frame, g.kind === "ellipse")
      })
    }
  }
}

export const lid = newId()
export const shine = newId()
export const lidRest = lidCentre(render(withLashes))
export const browAnchor = newId()
export const squint = newId()
const annoyedBrow = newId()
const madBrow = newId()
const BROW = 63.465 * 0.78
const browY = 270 - BROW - body.rise

export function rowAnimation(name: string, up: number): { id: string; xml: string } {
  const tracks: Track = new Map()
  TURNS.forEach((turn, k) => {
    const frame = k * 15
    const lidRoot = render(withLashes, pose({ turn, up }))
    const c = lidCentre(lidRoot)
    addKey(tracks, lid, "x", frame, c[0])
    addKey(tracks, lid, "y", frame, c[1])
    addKey(tracks, browAnchor, "x", frame, c[0])
    for (const b of builtFace) {
      const root = render(b.fp.config, pose({ turn, up }))
      const items = match(b.neutral, partItems(b.fp, root))
      b.neutral.forEach((n, i) => keyItem(tracks, b.ids[i], items[i] ?? null, n, frame))
      keyClips(tracks, b, root, frame)
    }
  })
  const id = newId()
  const objs = [...tracks]
    .map(([obj, props]) => {
      const ps = [...props]
        .map(([p, keys]) => {
          const vals = keys.map(([, v]) => v)
          const fixed = p.toLowerCase().includes("rotation")
            ? unwrap(vals, vals[2] ?? vals[0])
            : vals
          return `<KeyedProperty property="${p}">${keys.map(([fr], i) => `<KeyFrameDouble value="${f(fixed[i])}" frame="${fr}" interpolationType="linear"/>`).join("")}</KeyedProperty>`
        })
        .join("")
      return `<KeyedObject objectId="${obj}">${ps}</KeyedObject>`
    })
    .join("")
  return {
    id,
    xml: `<LinearAnimation duration="60" name="Row ${name}" id="${id}">${objs}</LinearAnimation>`
  }
}

export const rows = {
  up: rowAnimation("Up", ROWS.up),
  mid: rowAnimation("Mid", ROWS.mid),
  down: rowAnimation("Down", ROWS.down)
}

export const faceToggle = (name: string, p: string, xml: string) =>
  `<Node name="${name}" id="${newId()}">${bindFace(p, 18)}${xml}</Node>`
export const xmlOf = (name: string) => builtFace.find((b) => b.fp.name === name)!.xml
export const eyewearChildren = [{ id: newId(), xml: "" }]
eyewearChildren[0].xml = `<Node name="none" id="${eyewearChildren[0].id}"/>`
for (const e of botMascotEyewear) {
  const id = newId()
  eyewearChildren.push({ id, xml: `<Node name="${e.id}" id="${id}">${xmlOf(e.id)}</Node>` })
}
const FACE_CLIP_FRAME = [
  [-500, -500],
  [1000, -500],
  [1000, 1000],
  [-500, 1000]
]
export const faceClipXml = `<Shape name="Face body clip" id="${faceBodyClip}"><PointsPath isClosed="true" name="Path">${FACE_CLIP_FRAME.map(([x, y]) => `<StraightVertex x="${x}" y="${y}"/>`).join("")}</PointsPath></Shape>`

export const blinkAnim = newId()
export const shineAt = (b: number) => s01((b - 0.3) / 0.2)
export const blinkXml = `<LinearAnimation duration="60" name="Blink" id="${blinkAnim}"><KeyedObject objectId="${lid}"><KeyedProperty property="scaleY"><KeyFrameDouble value="1" frame="0" interpolationType="linear"/><KeyFrameDouble value="0.08" frame="60" interpolationType="linear"/></KeyedProperty></KeyedObject><KeyedObject objectId="${shine}"><KeyedProperty property="opacity">${Array.from({ length: 11 }, (_, k) => `<KeyFrameDouble value="${f(shineAt(1 - 0.92 * (k / 10)))}" frame="${k * 6}" interpolationType="linear"/>`).join("")}</KeyedProperty></KeyedObject></LinearAnimation>`
export const faceBoard = newId()
export const faceSm = newId()
export const faceStyle = newId()
const eyeInk = bindFor("face", "face")(0)
const openPath = (d: string): Contour => ({
  closed: false,
  vertices: pathContours(d)[0]?.vertices ?? []
})
const line = (d: string, width: number) =>
  `${pointsPath(
    openPath(d),
    openPath(d).vertices.map(() => newId())
  )}<Stroke thickness="${width}" cap="round" join="round" name="Ink"><SolidColor colorValue="FF3B2410" name="C">${eyeInk}</SolidColor></Stroke>`
const browsXml = `<Node x="${f(lidRest[0])}" y="${f(browY)}" name="Brows" id="${browAnchor}">
<Shape opacity="0" name="Annoyed brow" id="${annoyedBrow}">${line(`M${f(-BROW * 0.8)} 6L${f(BROW * 0.8)} -6`, 8)}</Shape>
<Shape opacity="0" name="Mad brow" id="${madBrow}">${line(`M${f(-BROW)} 0L0 20L${f(BROW)} 0`, 10)}</Shape>
</Node>`
const key = (frame: number, value: number) =>
  `<KeyFrameDouble value="${f(value)}" frame="${frame}" interpolationType="linear"/>`
export const annoyedAnim = newId()
export const madAnim = newId()
const moodXml = `<LinearAnimation duration="60" name="Annoyed" id="${annoyedAnim}"><KeyedObject objectId="${annoyedBrow}"><KeyedProperty property="rotation">${key(0, 0)}${key(60, (22 * Math.PI) / 180)}</KeyedProperty><KeyedProperty property="opacity">${key(0, 0)}${key(3, 1)}${key(60, 1)}</KeyedProperty></KeyedObject></LinearAnimation>
<LinearAnimation duration="60" name="Mad" id="${madAnim}"><KeyedObject objectId="${squint}"><KeyedProperty property="scaleY">${key(0, 1)}${key(60, 0.8)}</KeyedProperty><KeyedProperty property="y">${key(0, 0)}${key(60, 6)}</KeyedProperty></KeyedObject><KeyedObject objectId="${madBrow}"><KeyedProperty property="opacity">${key(0, 0)}${key(60, 1)}</KeyedProperty></KeyedObject></LinearAnimation>`

export const faceArtboard = `<Artboard isComponent="true" width="500" height="500" styleId="${faceStyle}" defaultStateMachineId="${faceSm}" viewModelId="${faceVm.id}" viewModelInstanceId="${faceVm.inst}" name="Face" id="${faceBoard}">
<LayoutComponentStyle name="Artboard Style" id="${faceStyle}"/>
<StateMachine name="Face" id="${faceSm}"><StateMachineLayer name="Rest" id="${newId()}"><AnyState/><ExitState/><EntryState/></StateMachineLayer></StateMachine>
${solo("Eyewear", prop.eyewear, bindFace, eyewearChildren)}
${browsXml}
<Node x="${f(lidRest[0])}" y="${f(lidRest[1])}" name="Lid" id="${lid}">
<Node name="Squint" id="${squint}">
${faceToggle("Lashes", prop.lashesOn, xmlOf("lashes"))}
<Node name="Shine" id="${shine}">${xmlOf("shine")}</Node>
<Node name="Eye" id="${newId()}">${xmlOf("eye")}</Node>
</Node>
</Node>
${faceToggle("Freckles", prop.frecklesOn, xmlOf("freckles"))}
${faceToggle("Blush", prop.blushOn, xmlOf("blush"))}
${faceClipXml}
${rows.up.xml}
${rows.mid.xml}
${rows.down.xml}
${blinkXml}
${moodXml}
</Artboard>
<ComponentAsset artboardId="${faceBoard}" name="Face"/>`
