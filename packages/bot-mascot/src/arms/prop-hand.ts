import type { Palette } from "../color/palette.js"
import { pointText, RAD, type Point } from "../geometry/math.js"
import { spineTip, type RigArm } from "./rig-arm.js"

export const HAND = { len: 29, w: 22, round: 2.4 } as const

const HAND_POINTS = 48

export function handOverGrip(arm: RigArm, P: Palette, grad: string): string {
  const sc = Math.max(0.4, arm.scale ?? 1)
  const { tip: G, dir } = spineTip(arm)
  const a0 = dir * RAD
  const ax: Point = [Math.cos(a0), Math.sin(a0)]
  const ay: Point = [-ax[1], ax[0]]
  const hl = HAND.len * sc
  const hw = HAND.w * sc
  const n = HAND.round
  const pts: Array<Point> = []
  for (let k = 0; k < HAND_POINTS; k++) {
    const t = (2 * Math.PI * k) / HAND_POINTS
    const c = Math.cos(t)
    const sn = Math.sin(t)
    const x = (Math.sign(c) * Math.abs(c) ** (2 / n) * hl) / 2
    const y = (Math.sign(sn) * Math.abs(sn) ** (2 / n) * hw) / 2
    pts.push([G[0] + ax[0] * x + ay[0] * y, G[1] + ax[1] * x + ay[1] * y])
  }
  const hd = `M${pts.map(pointText).join("L")}Z`
  return `<path data-r="hand" d="${hd}" fill="none" stroke="${P.outline}" stroke-width="16" stroke-linejoin="round"/><path d="${hd}" fill="url(#${grad})"/>`
}
