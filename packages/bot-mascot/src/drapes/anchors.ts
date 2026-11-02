import { deform, weigh } from "../body/rig.js"
import type { Body } from "../body/zones.js"
import type { Point } from "../geometry/math.js"
import type { Dangle } from "../outfits/outfits.js"
import type { BotMascotPose } from "../pose.js"

export interface AnchorPose extends BotMascotPose {
  readonly neck?: boolean
  readonly waist?: boolean
}

export function anchorAt(body: Body, pose: AnchorPose, q: Point): Point {
  const p = deform(pose, q, weigh(q))
  if (pose.neck) return body.zones ? [p[0], p[1] - body.zones.neck] : p
  if (pose.waist) return body.waistMap(p)
  return body.zoneMap(p)
}

export function toWorld(pose: BotMascotPose, [x, y]: Point): Point {
  const sy = pose.sy ?? 1
  const sx = 2 - sy
  const a = ((pose.lean || 0) * Math.PI) / 180
  const c = Math.cos(a)
  const sn = Math.sin(a)
  const u = (x - 250) * sx
  const v = (y - 412) * sy
  return [250 + u * c - v * sn, 412 - (pose.y || 0) + u * sn + v * c]
}

export function toLocal(pose: BotMascotPose, [X, Y]: Point): Point {
  const sy = pose.sy ?? 1
  const sx = 2 - sy
  const a = ((pose.lean || 0) * Math.PI) / 180
  const c = Math.cos(a)
  const sn = Math.sin(a)
  const u = X - 250
  const v = Y - (412 - (pose.y || 0))
  return [250 + (u * c + v * sn) / sx, 412 + (-u * sn + v * c) / sy]
}

export function plumb(body: Body, pose: AnchorPose, o: Dangle): Point {
  const K = toWorld(pose, anchorAt(body, pose, o.anchor))
  const l = ((o.lean || 0) * Math.PI) / 180
  return toLocal(pose, [K[0] + Math.sin(l) * o.L, K[1] + Math.cos(l) * o.L])
}
