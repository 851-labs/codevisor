import { colorOf } from "../color/colors.js"
import type { BotMascotPose, FacePose } from "../pose.js"
import { eyewearItem } from "./eyewear.js"

export interface FaceState extends FacePose {
  readonly eyewear?: string | undefined
  readonly eyewearOp?: number | undefined
  readonly eyewearDy?: number | undefined
  readonly eyewearColor?: string | undefined
  readonly blush: boolean
  readonly blushColor?: string | undefined
  readonly freckles: boolean
  readonly lashes: boolean
}

export function faceState(pose: BotMascotPose): FaceState {
  const w = pose.wear || {}
  const m = w.makeup || { blush: true }
  const blush = m.blush !== false && !!m.blush
  return {
    ...pose.face,
    eyewear: w.eyewear,
    eyewearOp: w.eyewearOp,
    eyewearDy: w.eyewearDy,
    eyewearColor: colorOf(eyewearItem(w.eyewear), w.eyewearColor, undefined),
    blush,
    blushColor: chosenBlush(blush, w.blushColor),
    freckles: !!m.freckles,
    lashes: !!m.lashes
  }
}

function chosenBlush(blush: boolean, color: string | undefined): string | undefined {
  if (!blush || !color || color === "auto") return undefined
  return colorOf({ colors: "blush" }, color)
}
