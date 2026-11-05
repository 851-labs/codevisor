import type { Palette } from "../color/palette.js"
import {
  clamp,
  f2,
  lerp2,
  normalize,
  pointText,
  RAD,
  s01,
  subtract,
  type Point
} from "../geometry/math.js"
import { LIGHT } from "../render/frame.js"
import { armEdges, type EdgeSample } from "./arm-edges.js"
import { mouthOf } from "./arm-mouth.js"
import { armRing, twists, type ArmRing } from "./arm-ring.js"
import { outlinePoly, signedDistance, type Poly } from "./outline-poly.js"
import {
  ARM_LENGTH,
  grownBy,
  rootRadius,
  spineTip,
  type ArmSleeve,
  type RigArm
} from "./rig-arm.js"

export interface ArmDrawing {
  readonly ring: ReadonlyArray<Point>
  readonly defs: string
  readonly art: string
  readonly fill: string
  readonly ends: readonly [Point, Point]
  readonly shapes: ReadonlyArray<string>
  readonly wc: number
  readonly rootReach: number
  readonly topStart: Point
  readonly tip: Point
  readonly nT: number
  readonly NC: number
  readonly poly: ReadonlyArray<Point>
  readonly slv: ReadonlyArray<Point> | null
}

const NUDGE = `${LIGHT[0]} ${LIGHT[1]}`
const MARGIN = 40
const HAND_FORM = 11
const SLOT_OPEN = 40
const OPEN_FROM = 0.55

export const lineTo = (q: ReadonlyArray<Point>): string => q.map((p) => `L${pointText(p)}`).join("")

export function drawArm(
  body: string,
  arm: RigArm,
  side: number,
  P: Palette,
  grad: string,
  id: string,
  shade: boolean
): ArmDrawing {
  const poly = outlinePoly(body)
  const { ts, bs, cap } = armEdges(arm, side)
  const sc = arm.scale ?? 1
  const tsF = ts.filter((q) => q.s >= 0)
  const mouth = mouthOf(poly, arm, tsF, bs)
  const picked = pickRing(
    armRing(mouth, mouth.preferred, tsF, bs, cap),
    armRing(mouth, -mouth.preferred, tsF, bs, cap)
  )
  const { nT, NC, top, bot } = picked
  const ring = throughSlot(poly, arm, picked.ring)
  const back = closingRun(poly, picked.endT, picked.endB)
  const fill = `M${pointText(ring[0]!)}${lineTo([...ring.slice(1), ...back])}Z`
  const wc = crescentWeight(poly, arm, ring[nT + (NC >> 1)]!, sc)
  const mk = maskMaker(id, ring)
  let defs = mk("mf", "#000", `<path d="${fill}" fill="#fff"/>`)
  let shadeEl = ""
  if (shade) {
    const bodyShade = wc > 0.001 ? `<path d="${body}" fill-opacity="${f2(s01(wc / 0.3))}"/>` : ""
    defs += mk(
      "sa",
      "#fff",
      `<g transform="translate(${NUDGE})" fill="#000"><path d="${fill}"/>${bodyShade}</g>`
    )
    shadeEl = `<rect ${mk.box} fill="${P.shade}" mask="url(#${id}sa)"/>`
  }
  const sleeve =
    arm.sleeve && arm.L > 4 ? sleeveCloth(arm, arm.sleeve, side, P, id, fill, picked, back) : null
  if (sleeve)
    defs += mk(
      "sm",
      "#000",
      `<path d="M${pointText(sleeve.pts[0]!)}${lineTo(sleeve.pts.slice(1))}Z" fill="#fff"/>`
    )
  if (sleeve)
    defs += mk(
      "mc",
      "#000",
      `<path d="${fill}" fill="#fff" stroke="#fff" stroke-width="3" stroke-linejoin="round"/>`
    )
  const art =
    `<path d="${fill}" fill="url(#${grad})"/>` +
    (shadeEl ? `<g mask="url(#${id}mf)">${shadeEl}</g>` : "") +
    (sleeve ? `<g mask="url(#${id}mc)">${sleeve.svg}</g>` : "")
  return {
    ring,
    defs,
    art,
    fill,
    ends: [picked.endT, picked.endB],
    shapes: [fill],
    wc,
    rootReach: rootRadius(arm),
    topStart: top[0]!,
    tip: bot[bot.length - 1]!,
    nT,
    NC,
    poly: [...ring, ...back],
    slv: sleeve?.pts ?? null
  }
}

export interface Slot {
  readonly at: Point
  readonly keep: Point
}

export function slotOf(poly: Poly, arm: RigArm): Slot | null {
  if (!arm.pivot) return null
  const { q, n } = signedDistance(poly, arm.pivot)
  const a = (arm.th + arm.turn(0)) * RAD
  const outward = Math.cos(a) * n[0] + Math.sin(a) * n[1] > 0
  const keep: Point = outward ? n : [-n[0], -n[1]]
  const open = SLOT_OPEN * slotOpening(arm)
  return { at: [q[0] - keep[0] * open, q[1] - keep[1] * open], keep }
}

export function handEmergence(poly: Poly, arm: RigArm): number {
  if (!arm.pivot) return 1
  const { q, n } = signedDistance(poly, arm.pivot)
  const a = (arm.th + arm.turn(0)) * RAD
  const outward = Math.cos(a) * n[0] + Math.sin(a) * n[1] > 0
  const keep: Point = outward ? n : [-n[0], -n[1]]
  const tip = spineTip(arm).tip
  const clear = (tip[0] - q[0]) * keep[0] + (tip[1] - q[1]) * keep[1]
  return Math.max(s01(clear / HAND_FORM), slotOpening(arm))
}

const slotOpening = (arm: RigArm): number => s01((grownBy(arm) - OPEN_FROM) / (1 - OPEN_FROM))

function throughSlot(poly: Poly, arm: RigArm, ring: ReadonlyArray<Point>): ReadonlyArray<Point> {
  const slot = slotOf(poly, arm)
  if (!slot) return ring
  const past = ring.map(
    (p) => (p[0] - slot.at[0]) * slot.keep[0] + (p[1] - slot.at[1]) * slot.keep[1]
  )
  if (past.every((v) => v < 0)) return ring.map(() => slot.at)
  const out = [...ring]
  for (const run of hiddenRuns(past)) {
    const a =
      crossing(ring, past, run.from - 1, run.from) ?? crossing(ring, past, run.to, run.to + 1)!
    const b = crossing(ring, past, run.to, run.to + 1) ?? a
    const n = run.to - run.from + 1
    for (let k = 0; k < n; k++) out[run.from + k] = lerp2(a, b, (k + 1) / (n + 1))
  }
  return out
}

interface Run {
  readonly from: number
  readonly to: number
}

function hiddenRuns(past: ReadonlyArray<number>): Run[] {
  const runs: Run[] = []
  let from = -1
  past.forEach((v, i) => {
    if (v < 0 && from < 0) from = i
    if (v >= 0 && from >= 0) {
      runs.push({ from, to: i - 1 })
      from = -1
    }
  })
  if (from >= 0) runs.push({ from, to: past.length - 1 })
  return runs
}

function crossing(
  ring: ReadonlyArray<Point>,
  past: ReadonlyArray<number>,
  i: number,
  j: number
): Point | null {
  if (i < 0 || j >= ring.length) return null
  const u = past[i]! / (past[i]! - past[j]!)
  return lerp2(ring[i]!, ring[j]!, u)
}

function pickRing(preferred: ArmRing, other: ArmRing): ArmRing {
  return twists(preferred) && !twists(other) ? other : preferred
}

function closingRun(poly: Poly, endT: Point, endB: Point): ReadonlyArray<Point> {
  const N = poly.length
  const nearest = (q: Point): number => {
    let bi = 0
    let bd = 1e18
    for (let i = 0; i < N; i++) {
      const d = (poly[i]![0] - q[0]) ** 2 + (poly[i]![1] - q[1]) ** 2
      if (d < bd) {
        bd = d
        bi = i
      }
    }
    return bi
  }
  const iT = nearest(endT)
  const iB = nearest(endB)
  const fw = (iT - iB + N) % N
  const stp = fw <= N / 2 ? 1 : -1
  const cnt = stp > 0 ? fw : N - fw
  const back: Array<Point> = []
  for (let m = 1; m < cnt; m++) back.push(poly[(iB + stp * m + N) % N]!)
  return back
}

function crescentWeight(poly: Poly, arm: RigArm, tipPoint: Point, sc: number): number {
  const tipIn = -signedDistance(poly, tipPoint).d
  const short = (1 - s01((arm.L / ARM_LENGTH - 0.8) / 0.8)) * (1 - s01((tipIn - 8) / 14))
  return Math.max(short, 1 - s01((sc - 0.3) / 0.3))
}

interface MaskMaker {
  (m: string, bg: string, inner: string): string
  readonly box: string
}

function maskMaker(id: string, ring: ReadonlyArray<Point>): MaskMaker {
  const xs = ring.map((p) => p[0])
  const ys = ring.map((p) => p[1])
  const bx = [
    Math.min(...xs) - MARGIN,
    Math.min(...ys) - MARGIN,
    Math.max(...xs) - Math.min(...xs) + 2 * MARGIN,
    Math.max(...ys) - Math.min(...ys) + 2 * MARGIN
  ].map(f2)
  const box = `x="${bx[0]}" y="${bx[1]}" width="${bx[2]}" height="${bx[3]}"`
  const mk = (m: string, bg: string, inner: string): string =>
    `<mask id="${id}${m}" maskUnits="userSpaceOnUse" ${box}><rect ${box} fill="${bg}"/>${inner}</mask>`
  return Object.assign(mk, { box })
}

interface SleeveCloth {
  readonly svg: string
  readonly pts: ReadonlyArray<Point>
}

function sleeveCloth(
  arm: RigArm,
  sv: ArmSleeve,
  side: number,
  P: Palette,
  id: string,
  fill: string,
  r: ArmRing,
  back: ReadonlyArray<Point>
): SleeveCloth {
  const sc = arm.scale ?? 1
  const sC = sv.len * arm.L
  const tA = pointAlong(r.topL, r.top, sC)
  const tB = pointAlong(r.botL, r.bot, sC)
  const cw = 6 * clamp(sc, 0.4, 1)
  const cu = normalize(subtract(tA, tB))
  const ax: Point = side > 0 ? [-cu[1], cu[0]] : [cu[1], -cu[0]]
  const cuff = sv.cuff
    ? `<path d="M${pointText([tB[0] - cu[0] * 6 - (ax[0] * cw) / 2, tB[1] - cu[1] * 6 - (ax[1] * cw) / 2])}L${pointText([tA[0] + cu[0] * 6 - (ax[0] * cw) / 2, tA[1] + cu[1] * 6 - (ax[1] * cw) / 2])}" stroke="${sv.cuff}" stroke-width="${f2(cw)}"/>`
    : ""
  const seam = `<path d="M${pointText([tB[0] - cu[0] * 6, tB[1] - cu[1] * 6])}L${pointText([tA[0] + cu[0] * 6, tA[1] + cu[1] * 6])}" stroke="${P.outline}" stroke-width="${f2(3.5 * clamp(sc, 0.5, 1))}" stroke-linecap="round"/>`
  const svg = `<path d="${fill}" fill="${sv.c}" mask="url(#${id}sm)"/>` + cuff + seam
  const iT = Math.max(1, r.topL.filter((q) => q.s <= sC).length - 1)
  const iB = Math.max(1, r.botL.filter((q) => q.s <= sC).length - 1)
  const nR = r.ring.length
  return {
    svg: sv.op < 0.999 ? `<g opacity="${f2(sv.op)}">${svg}</g>` : svg,
    pts: [...r.ring.slice(0, iT + 1), tA, tB, ...r.ring.slice(nR - 1 - iB), ...back]
  }
}

function pointAlong(list: ReadonlyArray<EdgeSample>, pp: ReadonlyArray<Point>, x: number): Point {
  let i = 1
  while (i < list.length - 1 && list[i]!.s < x) i++
  const q0 = list[i - 1]!
  const q1 = list[i]!
  const u = clamp((x - q0.s) / (q1.s - q0.s || 1), 0, 1)
  return lerp2(pp[i - 1]!, pp[i]!, u)
}
