import type { Body } from "../body/zones.js"
import type { Palette } from "../color/palette.js"
import { rotateAboutRadians, type Point } from "../geometry/math.js"
import { outfitItem, type Dangle, type OutfitItem } from "../outfits/outfits.js"
import type { BotMascotPose } from "../pose.js"
import { anchorAt, plumb } from "./anchors.js"
import {
  bundleClearance,
  bundleSwing,
  clearance,
  linePts,
  meetsNarrowly,
  type BundlePiece,
  type DrapeArm
} from "./drape-clearance.js"
import { anchorPoseOf, drapeSvg } from "./drape.js"

export type { DrapeArm } from "./drape-clearance.js"

export interface DrapedFrame {
  readonly body: Body
  readonly P: Palette
  readonly pose: BotMascotPose
  readonly uid: string
}

export interface RedrapedPiece {
  readonly id: string
  readonly w: number
  readonly pts: ReadonlyArray<Point>
  readonly hidden: boolean
}

export interface Redraped {
  readonly svg: string | null
  readonly pieces: ReadonlyArray<RedrapedPiece>
  readonly over: Readonly<Record<number, DrapeArm>>
}

interface SwingState {
  t: number
  a: number
  v: number
  under: Record<string, boolean>
}

const MAX_SWINGS = 64
const FRESH_AFTER_MS = 250
const LEVEL = (86 * Math.PI) / 180
const SPRING_HZ = 3.2

export class DrapeSwings {
  private readonly states = new Map<string, SwingState>()

  get(uid: string): SwingState | undefined {
    return this.states.get(uid)
  }

  set(uid: string, st: SwingState): void {
    this.states.set(uid, st)
    if (this.states.size > MAX_SWINGS) this.states.delete(this.states.keys().next().value!)
  }
}

interface Bundle {
  readonly item: OutfitItem
  readonly dangles: ReadonlyArray<Dangle>
  readonly idx: ReadonlyArray<number>
  readonly S: ReadonlyArray<Point>
  readonly tips0: ReadonlyArray<Point>
  readonly pieces: ReadonlyArray<BundlePiece>
  readonly hang: number
}

export function redrape(
  frame: DrapedFrame,
  arms: ReadonlyArray<DrapeArm>,
  swings: DrapeSwings,
  now: number
): Redraped | null {
  const bundle = bundleOf(frame)
  if (!bundle) return null

  const prior = swings.get(frame.uid)
  const fresh = !prior || now - prior.t > FRESH_AFTER_MS
  const st: SwingState = fresh || !prior ? { t: now, a: 0, v: 0, under: {} } : prior
  const { target, over } = swingTarget(bundle, arms, st, fresh)
  forgetGoneArms(st, arms)
  settle(st, target, fresh, now)
  swings.set(frame.uid, st)

  const tips = bundle.tips0.map((T, i) =>
    bundle.idx.includes(i) && st.a ? rotateAboutRadians(T, bundle.S[bundle.idx[0]!]!, st.a) : T
  )
  return finish(frame, bundle, arms, over, tips)
}

function bundleOf({ body, pose }: DrapedFrame): Bundle | null {
  const w = pose.wear || {}
  const item = outfitItem(w.outfit)
  if (!item?.dangles?.some((o) => o.role === "drape")) return null
  const dangles = item.dangles
  const np = anchorPoseOf(pose, item)
  const idx = dangles.map((o, i) => (o.role === "drape" ? i : -1)).filter((i) => i >= 0)
  const S = dangles.map((o) => anchorAt(body, np, o.anchor))
  const tips0 = dangles.map((o, i) => w.tips?.[i] || plumb(body, np, o))
  const pieces = idx.map((i) => ({ S: S[i]!, T: tips0[i]!, w: dangles[i]!.w || 12 }))
  const ax = idx.reduce((s2, i) => s2 + S[i]![0], 0) / (idx.length || 1)
  const hang = Math.abs(ax - 250) > 25 ? Math.sign(ax - 250) : 0
  return { item, dangles, idx, S, tips0, pieces, hang }
}

function swingTarget(
  bundle: Bundle,
  arms: ReadonlyArray<DrapeArm>,
  st: SwingState,
  fresh: boolean
): { target: number; over: Record<number, DrapeArm> } {
  const over: Record<number, DrapeArm> = {}
  let target = 0
  for (const arm of arms) {
    if (bundle.hang && arm.key === bundle.hang) {
      const side = sideArmSwing(bundle, arm, st, fresh)
      if (side.target !== null) target = side.target
      if (side.under) over[arm.key] = arm
    } else if (!target) {
      target = bundleSwing(
        bundle.pieces,
        arm.pts.filter((q) => !q.root),
        0,
        30
      )
    }
  }
  return { target, over }
}

function sideArmSwing(
  bundle: Bundle,
  arm: DrapeArm,
  st: SwingState,
  fresh: boolean
): { target: number | null; under: boolean } {
  const { pieces } = bundle
  const tip = arm.pts[arm.pts.length - 1]!.p
  const out = arm.tipOut ?? 0
  const was = st.under[arm.key] ?? true
  const low = tip[1] - arm.R[1]
  const wantUnder = was ? low > -10 && out < 14 : low > -2 && out < 6
  const T = pieces[0]!.T
  const d = rotateAboutRadians(T, pieces[0]!.S, 0.1)[0] - T[0]
  const sg = Math.sign(d * -bundle.hang) || 1
  const target = wantUnder ? null : pushInward(pieces, arm, sg)
  const roots = arm.pts.filter((q) => q.root)
  const nowTips = pieces.map(({ T: T0 }) => rotateAboutRadians(T0, pieces[0]!.S, st.a))
  const clear =
    Math.min(...pieces.map((pc, k) => clearance(linePts(pc.S, nowTips[k]!, 3), pc.w, roots))) >= 2
  const under = wantUnder === was || clear || fresh ? wantUnder : was
  st.under[arm.key] = under
  return { target, under }
}

function pushInward(pieces: ReadonlyArray<BundlePiece>, arm: DrapeArm, sg: number): number {
  const C0 = pieces[0]!.S
  const aAll = bundleSwing(pieces, arm.pts, sg, 75)
  let target =
    bundleClearance(pieces, arm.pts, aAll) >= 0
      ? aAll
      : bundleSwing(
          pieces,
          arm.pts.filter((q) => q.root),
          sg,
          75
        )
  const narrow = (a: number): boolean => pieces.some((pc) => meetsNarrowly(arm, C0, a, pc))
  for (let d = 0; d <= 40 && Math.abs(target) < LEVEL && narrow(target); d += 4)
    target += (sg * 4 * Math.PI) / 180
  return target
}

function forgetGoneArms(st: SwingState, arms: ReadonlyArray<DrapeArm>): void {
  for (const k of Object.keys(st.under))
    if (!arms.some((arm) => String(arm.key) === k)) delete st.under[k]
}

function settle(st: SwingState, target: number, fresh: boolean, now: number): void {
  if (fresh) {
    st.a = target
  } else {
    const dt = Math.min(0.1, (now - st.t) / 1000)
    const K = (2 * Math.PI * SPRING_HZ) ** 2
    const C = 2 * 0.6 * 2 * Math.PI * SPRING_HZ
    const n = Math.max(1, Math.ceil(dt * 240))
    const h = dt / n
    for (let j = 0; j < n; j++) {
      st.v += (K * (target - st.a) - C * st.v) * h
      st.a += st.v * h
    }
  }
  st.t = now
}

function finish(
  frame: DrapedFrame,
  bundle: Bundle,
  arms: ReadonlyArray<DrapeArm>,
  over: Record<number, DrapeArm>,
  tips: ReadonlyArray<Point>
): Redraped {
  const { body, P, pose, uid } = frame
  const hidden = hiddenPieces(bundle, arms, over, tips)
  const moved = tips.some(
    (T, i) => Math.hypot(T[0] - bundle.tips0[i]![0], T[1] - bundle.tips0[i]![1]) > 0.05
  )
  const w = pose.wear || {}
  return {
    svg: moved ? drapeSvg(body, P, { ...pose, wear: { ...w, tips } }, uid) : null,
    pieces: bundle.idx.map((i) => ({
      id: `${uid}dt${i}`,
      w: bundle.dangles[i]!.w || 12,
      pts: linePts(bundle.S[i]!, tips[i]!, 0),
      hidden: hidden.includes(i)
    })),
    over
  }
}

function hiddenPieces(
  bundle: Bundle,
  arms: ReadonlyArray<DrapeArm>,
  over: Record<number, DrapeArm>,
  tips: ReadonlyArray<Point>
): ReadonlyArray<number> {
  const hidden: Array<number> = []
  for (const arm of arms) {
    if (over[arm.key]) continue
    for (const i of bundle.idx) {
      const pts = linePts(bundle.S[i]!, tips[i]!, 0)
      const inArm = pts.filter((q) =>
        arm.pts.some((o) => Math.hypot(q[0] - o.p[0], q[1] - o.p[1]) < o.w)
      ).length
      if (inArm >= 0.75 * pts.length && !hidden.includes(i)) hidden.push(i)
    }
  }
  return hidden
}
