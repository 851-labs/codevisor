import type { CarryLayer } from "../../src/animations/working-flip.js"
import { handEmergence } from "../../src/arms/draw-arm.js"
import { outlinePoly } from "../../src/arms/outline-poly.js"
import { handScale, SMALLEST_HAND } from "../../src/arms/prop-hand.js"
import { spineTip } from "../../src/arms/rig-arm.js"
import type { ArmIds, HandIds, Side, SleeveIds } from "./arms.js"
import type { JoinIds } from "./join-rig.js"
import { armJoins, type ArmJoin, type UnionJoin } from "./joins.js"
import type { ArmSample, Sample } from "./motion.js"
import { sleeveCut, sleeveOutfits } from "./sleeves.js"
import { add, keyVertex, type Tracks } from "./tracks.js"

export interface ArmKeyIds {
  readonly arms: Readonly<Record<Side, ArmIds>>
  readonly joins: Readonly<Record<Side, JoinIds>>
  readonly hand: HandIds
  readonly sleeves: Readonly<Record<Side, ReadonlyMap<string, SleeveIds>>>
  readonly layers: Readonly<Record<CarryLayer, string>>
}

const SIDES = ["left", "right"] as const
const OUTLINE = 16

const sideSign = (side: Side): number => (side === "right" ? 1 : -1)

export function keyArms(tracks: Tracks, ids: ArmKeyIds, s: Sample, frame: number) {
  const joins = joinsOf(s)
  for (const side of SIDES) {
    const join = joins.get(side)
    keyArm(tracks, ids, s, side, join, frame)
    keyJoin(tracks, ids.joins[side], join?.union ?? null, frame)
  }
  keyHand(tracks, ids.hand, s, frame)
  keySleeves(tracks, ids, s, frame)
}

export function restArmKeys(tracks: Tracks, ids: ArmKeyIds) {
  for (const side of SIDES) {
    add(tracks, ids.arms[side].shape, "opacity", 0, 0)
    keyJoin(tracks, ids.joins[side], null, 0)
    for (const sl of ids.sleeves[side].values()) add(tracks, sl.node, "opacity", 0, 0)
  }
  add(tracks, ids.arms.left.shade, "opacity", 0, 0)
  add(tracks, ids.hand.node, "opacity", 0, 0)
}

function joinsOf(s: Sample): Map<Side, ArmJoin> {
  const present = SIDES.filter((side) => s.arms[side])
  const posed = present.map((side) => ({ side: sideSign(side), arm: s.arms[side]!.arm }))
  const joins = armJoins(s.body, posed)
  return new Map(present.map((side, i) => [side, joins[i]]))
}

function keyArm(
  tracks: Tracks,
  ids: ArmKeyIds,
  s: Sample,
  side: Side,
  join: ArmJoin | undefined,
  frame: number
) {
  const a = ids.arms[side]
  add(tracks, a.shape, "opacity", frame, join ? 1 : 0)
  if (side === "left") add(tracks, a.shade, "opacity", frame, join ? 1 : 0)
  if (!join) return

  join.contour.vertices.forEach((v, i) => keyVertex(tracks, a.vertices[i], v, frame))
  if (side === "left")
    join.contour.vertices.forEach((v, i) => keyVertex(tracks, a.shadeVertices[i], v, frame))
  a.lines.forEach((line, i) => {
    const trim = join.lines[i]
    add(tracks, line.trim, "start", frame, trim?.start ?? 0)
    add(tracks, line.trim, "end", frame, trim?.end ?? 0)
    add(tracks, line.stroke, "thickness", frame, trim ? OUTLINE : 0)
  })
  const layer = s.arms[side]?.layer ?? "front"
  if (side === "right") add(tracks, a.rules, "drawTargetId", frame, ids.layers[layer])
}

function keyJoin(tracks: Tracks, ids: JoinIds, union: UnionJoin | null, frame: number) {
  add(tracks, ids.shape, "opacity", frame, union ? 1 : 0)
  if (!union) return

  union.contour.vertices.forEach((v, i) => keyVertex(tracks, ids.vertices[i], v, frame))
  union.line.vertices.forEach((v, i) => keyVertex(tracks, ids.lineVertices[i], v, frame))
}

function keySleeves(tracks: Tracks, ids: ArmKeyIds, s: Sample, frame: number) {
  for (const side of SIDES) {
    const posed = s.arms[side]
    for (const outfit of sleeveOutfits) {
      const sl = ids.sleeves[side].get(outfit.id)!
      const cut = posed ? sleeveCut(posed.arm, sideSign(side), s.body, outfit.len) : null
      add(tracks, sl.node, "opacity", frame, cut ? 1 : 0)
      if (!cut) continue

      cut.cloth.forEach((p, i) => keyVertex(tracks, sl.cloth[i], { p }, frame))
      cut.seam.forEach((p, i) => keyVertex(tracks, sl.seam[i], { p: [p[0], p[1]] }, frame))
      cut.cuff.forEach((p, i) => keyVertex(tracks, sl.cuff[i], { p: [p[0], p[1]] }, frame))
      add(tracks, sl.seamStroke, "thickness", frame, cut.seamWidth)
      add(tracks, sl.cuffStroke, "thickness", frame, cut.cuffWidth)
    }
  }
}

function keyHand(tracks: Tracks, ids: HandIds, s: Sample, frame: number) {
  const right = s.arms.right
  const hand = right ? handPlacement(right, s.body) : null
  add(tracks, ids.node, "opacity", frame, hand?.opacity ?? 0)
  if (!right || !hand) return

  add(tracks, ids.node, "x", frame, hand.at[0])
  add(tracks, ids.node, "y", frame, hand.at[1])
  add(tracks, ids.node, "rotation", frame, (spineTip(right.arm).dir * Math.PI) / 180)
  add(tracks, ids.node, "scaleX", frame, hand.scale)
  add(tracks, ids.node, "scaleY", frame, hand.scale)
}

interface HandPlacement {
  readonly at: readonly [number, number]
  readonly scale: number
  readonly opacity: number
}

function handPlacement(a: ArmSample, body: string): HandPlacement | null {
  const size = a.hand * handEmergence(outlinePoly(body), a.arm)
  if (!(size > SMALLEST_HAND)) return null
  return { at: spineTip(a.arm).tip, scale: handScale(a.arm, size), opacity: 1 }
}
