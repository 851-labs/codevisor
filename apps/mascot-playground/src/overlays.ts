import {
  armEdges,
  armOrigin,
  composeArms,
  renderContext,
  shoulder,
  spinePoints,
  type PosedArm,
  type RigArm
} from "@codevisor/bot-mascot"

import type { SceneFrame } from "./animations.js"
import type { RigScene } from "./arm-rig.js"
import {
  overlayNames,
  type ArmControls,
  type ArmSide,
  type Overlays,
  type RigControls
} from "./state.js"
import { bodyTransformOf } from "./svg-text.js"

type Point = readonly [number, number]

type OverlayLayer = (scene: RigScene, frame: SceneFrame, rig: RigControls) => string

const colors = {
  silhouette: "#ff2d8a",
  top: "#00a2ff",
  bottom: "#ff9500",
  outline: "#34c759",
  points: "#af52de"
}

export function overlaySvg(scene: RigScene, frame: SceneFrame, rig: RigControls): string {
  const drawn = overlayNames
    .filter((name) => rig.overlays[name])
    .map((name) => layers[name](scene, frame, rig))
    .join("")
  if (!drawn) return ""

  return `<g transform="${bodyTransformOf(scene.base)}" pointer-events="none">${drawn}</g>`
}

const pathOf = (points: ReadonlyArray<Point>, closed: boolean): string =>
  points.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(2)} ${y.toFixed(2)}`).join("") +
  (closed ? "Z" : "")

const stroke = (d: string, color: string, dash = ""): string =>
  `<path d="${d}" fill="none" stroke="${color}" stroke-width="1.2"${dash ? ` stroke-dasharray="${dash}"` : ""}/>`

const dot = ([x, y]: Point, color: string, r = 3): string =>
  `<circle cx="${x.toFixed(2)}" cy="${y.toFixed(2)}" r="${r}" fill="${color}" stroke="#fff" stroke-width="0.8"/>`

const liveArms = (scene: RigScene): ReadonlyArray<PosedArm & { readonly arm: RigArm }> =>
  scene.arms.filter((p): p is PosedArm & { readonly arm: RigArm } => p.arm !== null)

const outline: OverlayLayer = (scene) => stroke(scene.torso.d, colors.outline, "4 3")

const silhouette: OverlayLayer = (scene, frame) => {
  const items = liveArms(scene).map((p) => ({ side: p.side, arm: p.arm, layer: p.layer }))
  const composed = composeArms(renderContext({ idPrefix: "ov" }), scene.base, items, {
    uid: "ov",
    pal: frame.look.color,
    pose: scene.pose
  })
  return Object.values(composed.arms)
    .map((arm) => stroke(pathOf(arm.d.ring, true), colors.silhouette))
    .join("")
}

const edges: OverlayLayer = (scene) =>
  liveArms(scene)
    .map((p) => {
      const sampled = armEdges(p.arm, p.side)
      return (
        stroke(
          pathOf(
            sampled.ts.map((q) => q.p),
            false
          ),
          colors.top
        ) +
        stroke(
          pathOf(
            sampled.bs.map((q) => q.p),
            false
          ),
          colors.bottom
        )
      )
    })
    .join("")

const points: OverlayLayer = (scene, _frame, rig) =>
  liveArms(scene)
    .map(
      (p) =>
        stroke(pathOf(spinePoints(p.arm), false), colors.points, "2 2") +
        dot(shoulder(scene.torso, p.side), colors.outline) +
        dot(armOrigin(scene.torso, p.side), colors.points) +
        dot(p.tip, colors.silhouette, 4) +
        targetMark(rig[sideOf(p.side)])
    )
    .join("")

const sideOf = (sign: number): ArmSide => (sign < 0 ? "left" : "right")

const targetMark = (controls: ArmControls): string => {
  if (controls.mode !== "reach") return ""

  const { x, y } = controls
  return stroke(`M${x - 6} ${y}H${x + 6}M${x} ${y - 6}V${y + 6}`, colors.top)
}

const layers: Readonly<Record<keyof Overlays, OverlayLayer>> = {
  outline,
  silhouette,
  edges,
  points
}
