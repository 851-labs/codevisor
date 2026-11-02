import type { Body } from "../body/zones.js"
import type { Palette } from "../color/palette.js"
import { f2 } from "../geometry/math.js"
import { outfitColor, outfitItem, type DrapeKind, type OutfitItem } from "../outfits/outfits.js"
import type { BotMascotPose } from "../pose.js"
import type { AnchorPose } from "./anchors.js"
import { dressSkirt, robe, tie, tutu, type DrapeDrawing } from "./drape-drawings.js"

const drawings: Readonly<Record<DrapeKind, DrapeDrawing>> = { tie, tutu, dress: dressSkirt, robe }

export const anchorPoseOf = (pose: BotMascotPose, item: OutfitItem): AnchorPose => ({
  ...pose,
  neck: !!item.neck,
  waist: !!item.waist
})

export function drapeSvg(body: Body, P: Palette, pose: BotMascotPose, uid: string): string {
  const w = pose.wear || {}
  const item = outfitItem(w.outfit)
  const op = w.clothesOp ?? 1
  if (!item?.drape || op <= 0.01) return ""
  const ctx = { body, pose: anchorPoseOf(pose, item), tips: w.tips, dangles: item.dangles || [] }
  const out = drawings[item.drape](P, outfitColor(P, pose, item), ctx, uid)
  return op < 0.999 ? `<g opacity="${f2(op)}">${out}</g>` : out
}
