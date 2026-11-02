import { f2, lerp, lerp2, normalize, RAD, type Point } from "../geometry/math.js"
import { ARM_LENGTH, FLIPPER, LS, type RigArm } from "./rig-arm.js"

export interface EdgeSample {
  readonly s: number
  readonly p: Point
}

export interface ArmEdges {
  readonly ts: ReadonlyArray<EdgeSample>
  readonly bs: ReadonlyArray<EdgeSample>
  readonly L: number
  readonly top0: Point
  readonly cap: string
  readonly capR: string
}

const SPINE_STEPS = 160
const BEHIND_ROOT = 24
const EDGE_STEPS = 120

export function armEdges(arm: RigArm, side: number): ArmEdges {
  const { L } = arm
  const at = spineWalker(arm)
  const sc = arm.scale ?? 1
  const pf = profileOf(L, sc)
  const sideNormal = (a: number): Point =>
    side > 0 ? [Math.sin(a), -Math.cos(a)] : [-Math.sin(a), Math.cos(a)]
  const top = (s: number): Point => {
    const q = at(s)
    const n = sideNormal(q.a)
    const h = sc * FLIPPER.hT(pf(s))
    return [q.p[0] + n[0] * h, q.p[1] + n[1] * h]
  }
  const bot = (s: number): Point => {
    const q = at(s)
    const n = sideNormal(q.a)
    const h = sc * FLIPPER.hB(pf(s))
    return [q.p[0] - n[0] * h, q.p[1] - n[1] * h]
  }
  const ts: Array<EdgeSample> = []
  const bs: Array<EdgeSample> = []
  for (let i = 0; i <= EDGE_STEPS; i++) {
    const s = -BEHIND_ROOT + ((L + BEHIND_ROOT) * i) / EDGE_STEPS
    ts.push({ s, p: top(s) })
  }
  for (let i = 0; i <= EDGE_STEPS; i++) {
    const s = (L * i) / EDGE_STEPS
    bs.push({ s, p: bot(s) })
  }
  return { ts, bs, L, top0: top(0), ...tipCaps(ts, bs, sc) }
}

interface SpineSample {
  readonly p: Point
  readonly a: number
}

function spineWalker(arm: RigArm): (s: number) => SpineSample {
  const { R, th, L, turn } = arm
  const pts: Array<Point> = [[...R]]
  const dirs = [th + turn(0)]
  for (let i = 0; i < SPINE_STEPS; i++) {
    const a = (th + turn((i + 0.5) / SPINE_STEPS)) * RAD
    const p = pts[i]!
    pts.push([p[0] + (Math.cos(a) * L) / SPINE_STEPS, p[1] + (Math.sin(a) * L) / SPINE_STEPS])
    dirs.push(th + turn((i + 1) / SPINE_STEPS))
  }
  return (s) => {
    if (s <= 0) {
      const a = dirs[0]! * RAD
      return { p: [R[0] + Math.cos(a) * s, R[1] + Math.sin(a) * s], a }
    }
    const f = Math.min(SPINE_STEPS, (s / L) * SPINE_STEPS)
    const i = Math.min(SPINE_STEPS - 1, Math.floor(f))
    const u = f - i
    return { p: lerp2(pts[i]!, pts[i + 1]!, u), a: lerp(dirs[i]!, dirs[i + 1]!, u) * RAD }
  }
}

function profileOf(L: number, sc: number): (s: number) => number {
  const Lf = 3.6 * ARM_LENGTH * sc
  const TIP = 0.65 * Math.min(L, Lf)
  const pTip = LS * 0.35
  return (s) => {
    if (L <= Lf) return (s * LS) / L
    if (s >= L - TIP) return pTip + ((s - (L - TIP)) / TIP) * (LS - pTip)
    return (Math.max(0, s) / (L - TIP)) * pTip
  }
}

function tipCaps(
  ts: ReadonlyArray<EdgeSample>,
  bs: ReadonlyArray<EdgeSample>,
  sc: number
): { cap: string; capR: string } {
  const M = EDGE_STEPS
  const Tt = ts[M]!.p
  const Tb = bs[M]!.p
  const tT = normalize([Tt[0] - ts[M - 1]!.p[0], Tt[1] - ts[M - 1]!.p[1]])
  const tB = normalize([Tb[0] - bs[M - 1]!.p[0], Tb[1] - bs[M - 1]!.p[1]])
  const cT = FLIPPER.cap[0] * sc
  const cB = FLIPPER.cap[1] * sc
  return {
    cap: `C${f2(Tt[0] + tT[0] * cT)} ${f2(Tt[1] + tT[1] * cT)} ${f2(Tb[0] + tB[0] * cB)} ${f2(Tb[1] + tB[1] * cB)} ${f2(Tb[0])} ${f2(Tb[1])}`,
    capR: `C${f2(Tb[0] + tB[0] * cB)} ${f2(Tb[1] + tB[1] * cB)} ${f2(Tt[0] + tT[0] * cT)} ${f2(Tt[1] + tT[1] * cT)} ${f2(Tt[0])} ${f2(Tt[1])}`
  }
}
