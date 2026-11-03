import {
  armOrigin,
  dressed,
  drawRig,
  growth,
  phoneProp,
  poseArm,
  renderBotMascotFrame,
  renderContext,
  scaled,
  spineTip,
  withHands,
  type BotMascotPose,
  type PosedArm,
  type RenderContext,
  type RigArm,
  type Torso
} from "@codevisor/bot-mascot"

import type { SceneFrame } from "./animations.js"
import { overlaySvg } from "./overlays.js"
import { armSides, sideSign, type ArmControls, type ArmMode, type RigControls } from "./state.js"
import { torsoOf, withOverlay } from "./svg-text.js"

export interface RigScene {
  readonly ctx: RenderContext
  readonly pose: BotMascotPose
  readonly base: string
  readonly torso: Torso
  readonly arms: ReadonlyArray<PosedArm>
}

type Poser = (
  torso: Torso,
  side: number,
  controls: ArmControls,
  frame: SceneFrame
) => PosedArm | null

const minimumGrowth = 0.02

export function renderRig(frame: SceneFrame, rigPose: BotMascotPose, rig: RigControls): string {
  const scene = rigScene(frame, rigPose, rig)
  const drawn = drawRig(scene.ctx, scene.base, scene.arms, {
    uid: `${frame.uid}a`,
    pal: frame.look.color,
    pose: scene.pose
  })
  return withOverlay(drawn, overlaySvg(scene, frame, rig))
}

function rigScene(frame: SceneFrame, rigPose: BotMascotPose, rig: RigControls): RigScene {
  const ctx = withHands(renderContext({ idPrefix: frame.uid }), () => "")
  const pose = dressed(frame.look)(rigPose)
  const base = renderBotMascotFrame(ctx, frame.look.color, pose, {
    viewBox: frame.viewBox,
    uid: frame.uid
  })
  const torso = torsoOf(base, ctx)
  const arms = armSides.flatMap((side) => {
    const posed = posedArm(torso, sideSign[side], rig[side], frame)
    return posed ? [posed] : []
  })
  return { ctx, pose, base, torso, arms }
}

function posedArm(
  torso: Torso,
  side: number,
  controls: ArmControls,
  frame: SceneFrame
): PosedArm | null {
  if (!controls.on) return null

  const posed = posers[controls.mode](torso, side, controls, frame)
  return posed ? { ...posed, layer: controls.layer } : null
}

function reachingArm(
  torso: Torso,
  side: number,
  controls: ArmControls,
  frame: SceneFrame
): PosedArm | null {
  return poseArm(torso, {
    side,
    grow: controls.grow,
    target: [controls.x, controls.y],
    t: frame.t,
    ...(controls.autoCurl ? {} : { curl: controls.curl }),
    ...(controls.prop === "phone" ? { grip: phoneProp(frame.look.color) } : {})
  })
}

function directArm(torso: Torso, side: number, controls: ArmControls): PosedArm | null {
  const g = growth(controls.grow)
  if (g < minimumGrowth) return null

  const arm = scaled(straightArm(torso, side, controls), g)
  const { tip, dir } = spineTip(arm)
  return { side, arm, tip, tipDir: dir, layer: controls.layer }
}

const posers: Readonly<Record<ArmMode, Poser>> = { reach: reachingArm, direct: directArm }

const straightArm = (torso: Torso, side: number, controls: ArmControls): RigArm => ({
  R: armOrigin(torso, side),
  th: side > 0 ? controls.angle : 180 - controls.angle,
  L: controls.length,
  turn: (u) => side * controls.bend * u
})
