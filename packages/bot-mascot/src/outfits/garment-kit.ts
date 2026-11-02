import { deform, isRest, weigh, type RigWeights } from "../body/rig.js"
import type { Body } from "../body/zones.js"
import { GOLD } from "../color/colors.js"
import type { Palette } from "../color/palette.js"
import { f2, type Point } from "../geometry/math.js"
import type { BotMascotPose } from "../pose.js"

export type ShapeMaker = () => ReadonlyArray<Point>
export type Profile = (x: number) => number

export interface GarmentKit {
  readonly d: (key: string, make: ShapeMaker, closed?: boolean) => string
  readonly pt: (x: number, y: number) => Point
  readonly id: string
  readonly zoned: boolean
  readonly zy: (y: number) => number
  readonly S: number
  readonly shoulderY: number
}

interface RestShape {
  readonly pts: ReadonlyArray<Point>
  readonly w: ReadonlyArray<RigWeights>
}

export const ARM_HALF = 15
const TOP_CLEAR = 12
const THREAD = "#F2A64A"
const shapes = new Map<string, RestShape>()

export function garmentKit(body: Body, pose: BotMascotPose, uid: string): GarmentKit {
  const rest = isRest(pose) && !body.zoned
  const place = (q: Point, w: RigWeights): Point => (rest ? q : body.zoneMap(deform(pose, q, w)))
  return {
    d: (key, make, closed = true) => {
      const sh = shapeOf(key, make)
      const p = sh.pts.map((q, i) => place(q, sh.w[i]!))
      return "M" + p.map(([x, y]) => `${f2(x)} ${f2(y)}`).join("L") + (closed ? "Z" : "")
    },
    pt: (x, y) => place([x, y], weigh([x, y])),
    id: uid,
    zoned: body.zoned,
    zy: body.zoneY,
    S: body.clothesShoulderY,
    shoulderY: body.shoulderY
  }
}

export const xsFrom = (x0 = 110, x1 = 390): Array<number> => {
  const a: Array<number> = []
  for (let x = x0; x <= x1; x += 4) a.push(x)
  return a
}

export const band =
  (top: Profile, bot: Profile): ShapeMaker =>
  () => {
    const a = xsFrom()
    return [...a.map((x): Point => [x, top(x)]), ...a.toReversed().map((x): Point => [x, bot(x)])]
  }

export const curve =
  (f: Profile, x0?: number, x1?: number): ShapeMaker =>
  () =>
    xsFrom(x0, x1).map((x): Point => [x, f(x)])

export const poly =
  (pts: ReadonlyArray<Point>, closed = false): ShapeMaker =>
  () => {
    const out: Array<Point> = []
    const n = closed ? pts.length : pts.length - 1
    for (let i = 0; i < n; i++) {
      const a = pts[i]!
      const b = pts[(i + 1) % pts.length]!
      const m = Math.max(1, Math.ceil(Math.hypot(b[0] - a[0], b[1] - a[1]) / 3))
      for (let j = 0; j < m; j++)
        out.push([a[0] + ((b[0] - a[0]) * j) / m, a[1] + ((b[1] - a[1]) * j) / m])
    }
    if (!closed) out.push(pts[pts.length - 1]!)
    return out
  }

export const level =
  (y: number): Profile =>
  () =>
    y

export const neckline =
  (dip: number): Profile =>
  (x) =>
    318 + dip * Math.exp(-(((x - 250) / 34) ** 2))

export const shouldered =
  (body: Body, f: Profile): Profile =>
  (x) => {
    if (!body.zoned) return f(x)
    const T = body.zoneY(body.shoulderY - ARM_HALF - TOP_CLEAR)
    const y = f(x)
    const u = Math.min(1, Math.abs(x - 250) / 86)
    return y + (Math.min(y, T) - y) * u * u
  }

export const edge = (P: Palette, d: string, w = 6): string =>
  `<path d="${d}" fill="none" stroke="${P.outline}" stroke-width="${w}" stroke-linejoin="round"/>`

export const seam = (P: Palette, d: string, w = 3.5, op = 0.45): string =>
  `<path d="${d}" fill="none" stroke="${P.outline}" stroke-opacity="${op}" stroke-width="${w}" stroke-linecap="round"/>`

export const stitch = (d: string): string =>
  `<path d="${d}" fill="none" stroke="${THREAD}" stroke-width="2.5" stroke-dasharray="5 4" stroke-linecap="round"/>`

export const button = (P: Palette, [x, y]: Point, r = 4.5): string =>
  `<circle cx="${f2(x)}" cy="${f2(y)}" r="${r}" fill="${GOLD}" stroke="${P.outline}" stroke-width="3"/>`

export function shoes(
  P: Palette,
  kit: GarmentKit,
  col: string,
  top = 398,
  key = "shoes"
): readonly [string, string] {
  const sd = kit.d(key, band(level(top), level(424)))
  const sole = seam(P, kit.d(`${key}-sole`, curve(level(407)), false), 3, 0.35)
  return [`<path d="${sd}" fill="${col}"/>` + sole + edge(P, sd, 5), sd]
}

function shapeOf(key: string, make: ShapeMaker): RestShape {
  const cached = shapes.get(key)
  if (cached) return cached
  const pts = make()
  const sh = { pts, w: pts.map(weigh) }
  shapes.set(key, sh)
  return sh
}
