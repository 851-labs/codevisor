import { poseArm, type ArmProp, type Matrix, type PosedArm } from "../arms/arm-pose.js"
import { handEmergence } from "../arms/draw-arm.js"
import { outlinePoly } from "../arms/outline-poly.js"
import { SMALLEST_HAND } from "../arms/prop-hand.js"
import { growFor, grownBy, type Torso } from "../arms/rig-arm.js"
import { s01, smootherstep } from "../geometry/math.js"
import { apply, matrixText, multiply } from "./matrix.js"

export const CALLING_EXIT = 0.5

const FLYING_MATRIX = /matrix\(([^)]+)\)/

export interface LeavingScene {
  readonly arm: PosedArm | null
  readonly flying: string
}

export function phoneLeaving(
  torso: Torso,
  TF: Matrix,
  arm: PosedArm | null,
  flying: string,
  phone: ArmProp,
  u: number
): LeavingScene {
  const M = phoneMatrix(TF, arm, flying)
  const x = u / 0.28
  const pop =
    x >= 1 ? 0 : 1 + 0.12 * Math.sin(Math.PI * Math.min(1, x / 0.35)) - s01((x - 0.3) / 0.7)
  const shrunk = shrinking(torso, arm, phone, u)
  const leaving = shrunk?.over ? { ...shrunk, over: Math.min(shrunk.over, pop) } : shrunk
  const k = Math.min(pop, handSize(torso, leaving))
  return { arm: leaving, flying: M && k > SMALLEST_HAND ? poppingPhone(M, k, phone.svg) : "" }
}

function phoneMatrix(TF: Matrix, arm: PosedArm | null, flying: string): Matrix | null {
  if (arm?.prop) return multiply(TF, arm.prop.M)
  if (!flying) return null
  const values = (FLYING_MATRIX.exec(flying)?.[1] ?? "").split(" ").map(Number)
  return [values[0]!, values[1]!, values[2]!, values[3]!, values[4]!, values[5]!]
}

function poppingPhone(M: Matrix, k: number, phoneSvg: string): string {
  const C = apply(M, [5, 0])
  const scaled = multiply([k, 0, 0, k, C[0] - k * C[0], C[1] - k * C[1]], M)
  return `<g transform="matrix(${matrixText(scaled)})">${phoneSvg}</g>`
}

function shrinking(torso: Torso, arm: PosedArm | null, phone: ArmProp, u: number): PosedArm | null {
  if (!arm?.arm) return null
  const g = grownBy(arm.arm) * (1 - smootherstep((u - 0.04) / 0.44))
  if (!(g > 0.005)) return null
  const posed = poseArm(torso, { side: 1, grow: growFor(g), target: arm.tip, grip: phone })
  return posed ? emptyHanded(posed) : null
}

function handSize(torso: Torso, p: PosedArm | null): number {
  if (!p?.arm) return 0
  return (p.over ?? 0) * handEmergence(outlinePoly(torso.d), p.arm)
}

function emptyHanded(p: PosedArm): PosedArm {
  const { side, arm, tip, tipDir, layer } = p
  return { side, arm, tip, tipDir, layer, ...(p.over === undefined ? {} : { over: p.over }) }
}
