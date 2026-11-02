import { poseArm, type Matrix, type PosedArm } from "../arms/arm-pose.js"
import type { Torso } from "../arms/rig-arm.js"
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
  phoneSvg: string,
  u: number
): LeavingScene {
  const M = phoneMatrix(TF, arm, flying)
  const x = u / 0.28
  const k = x >= 1 ? 0 : 1 + 0.12 * Math.sin(Math.PI * Math.min(1, x / 0.35)) - s01((x - 0.3) / 0.7)
  return {
    arm: shrinking(torso, arm, u),
    flying: M && k > 0.01 ? poppingPhone(M, k, phoneSvg) : ""
  }
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

function shrinking(torso: Torso, arm: PosedArm | null, u: number): PosedArm | null {
  if (!arm?.arm) return null
  const g = (arm.arm.scale ?? 1) * (1 - smootherstep((u - 0.08) / 0.4))
  if (!(g > 0.005)) return null
  return poseArm(torso, { side: 1, grow: g, target: arm.tip })
}
