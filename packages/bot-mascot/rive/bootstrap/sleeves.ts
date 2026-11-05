import { drawArm } from "../../src/arms/draw-arm.js"
import type { RigArm } from "../../src/arms/rig-arm.js"
import { palette } from "../../src/color/palette.js"
import { botMascotOutfits } from "../../src/index.js"
import { outfitItem } from "../../src/outfits/outfits.js"
import { withAlpha, type Item, type Pt } from "./collect.js"
import { rectContour, type El } from "./svg.js"

export interface SleeveCut {
  readonly cloth: ReadonlyArray<Pt>
  readonly seam: readonly [Pt, Pt]
  readonly cuff: readonly [Pt, Pt]
  readonly cuffWidth: number
  readonly seamWidth: number
}

export interface SleeveOutfit {
  readonly id: string
  readonly len: number
  readonly cuff: string
}

export const RUN_POINTS = 7
export const CLOTH_POINTS = 2 * RUN_POINTS

const OUTSET = 3
const OVERHANG = 6

export const sleeveOutfits: ReadonlyArray<SleeveOutfit> = botMascotOutfits.flatMap((o) => {
  const sleeve = outfitItem(o.id)?.sleeve
  return sleeve ? [{ id: o.id, len: sleeve.len, cuff: sleeve.cuff ?? "" }] : []
})

export function sleevePart(root: El): Item[] {
  const sleeve = root.children[0]?.attrs["data-sleeve"]
  if (!sleeve) return []
  return [
    {
      geometry: { kind: "path", contours: [rectContour(0, 0, 1, 1)] },
      fill: { kind: "solid", color: withAlpha(sleeve.split("|")[0], 1) },
      fillRule: "nonZero",
      stroke: null,
      strokeFirst: false,
      opacity: 1,
      clips: [],
      hole: null,
      blur: 0
    }
  ]
}

export function sleeveCut(arm: RigArm, side: number, body: string, len: number): SleeveCut | null {
  const sleeve = { c: "#000", len, cuff: "", op: 1 }
  const d = drawArm(body, { ...arm, sleeve }, side, palette("sunny"), "g", "a", false)
  if (!d.slv) return null
  const split = d.slv.findIndex((p, i) => p !== d.ring[i])
  const back = d.poly.length - d.ring.length
  const tA = asPt(d.slv[split])
  const tB = asPt(d.slv[split + 1])
  const top = d.ring.slice(0, split).map(asPt)
  const under = d.slv.slice(split + 2, d.slv.length - back).map(asPt)
  const cloth = [...resample([...top, tA], RUN_POINTS), ...resample([tB, ...under], RUN_POINTS)]
  return { ...lines(tA, tB, side, arm.scale ?? 1), cloth: outset(cloth) }
}

const asPt = (p: readonly [number, number]): Pt => [p[0], p[1]]

function lines(tA: Pt, tB: Pt, side: number, scale: number): Omit<SleeveCut, "cloth"> {
  const along = unit([tA[0] - tB[0], tA[1] - tB[1]])
  const across: Pt = side > 0 ? [-along[1], along[0]] : [along[1], -along[0]]
  const cuffWidth = 6 * clamp(scale, 0.4, 1)
  const seamWidth = 3.5 * clamp(scale, 0.5, 1)
  const end = (p: Pt, k: number, shift: number): Pt => [
    p[0] + along[0] * k * OVERHANG - across[0] * shift,
    p[1] + along[1] * k * OVERHANG - across[1] * shift
  ]
  return {
    seam: [end(tB, -1, 0), end(tA, 1, 0)],
    cuff: [end(tB, -1, cuffWidth / 2), end(tA, 1, cuffWidth / 2)],
    cuffWidth,
    seamWidth
  }
}

const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v))

const unit = (v: Pt): Pt => {
  const l = Math.hypot(v[0], v[1]) || 1
  return [v[0] / l, v[1] / l]
}

function resample(run: ReadonlyArray<Pt>, count: number): Pt[] {
  const arc = [0]
  for (let i = 1; i < run.length; i++)
    arc.push(arc[i - 1] + Math.hypot(run[i][0] - run[i - 1][0], run[i][1] - run[i - 1][1]))
  const total = arc[arc.length - 1]
  return Array.from({ length: count }, (_, k) => {
    const at = (total * k) / (count - 1)
    let i = 1
    while (i < run.length - 1 && arc[i] < at) i++
    const u = clamp((at - arc[i - 1]) / (arc[i] - arc[i - 1] || 1), 0, 1)
    const a = run[i - 1] ?? run[0]
    const b = run[i] ?? a
    return [a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u]
  })
}

function outset(pts: ReadonlyArray<Pt>): Pt[] {
  const area = pts.reduce((s, p, i) => {
    const q = pts[(i + 1) % pts.length]
    return s + p[0] * q[1] - q[0] * p[1]
  }, 0)
  const sign = area > 0 ? 1 : -1
  return pts.map((p, i) => {
    const a = pts[(i - 1 + pts.length) % pts.length]
    const b = pts[(i + 1) % pts.length]
    const t = unit([b[0] - a[0], b[1] - a[1]])
    return [p[0] + sign * t[1] * OUTSET, p[1] - sign * t[0] * OUTSET]
  })
}
