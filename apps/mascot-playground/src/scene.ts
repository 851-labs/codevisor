import { FIGURE_VIEW_BOX, portraitViewBox } from "@codevisor/bot-mascot"

import { animationById } from "./animations.js"
import { renderRig } from "./arm-rig.js"
import type { PlaygroundState } from "./state.js"

export type Framing = "stage" | "figure" | "portrait"

const stageViewBox = "0 0 500 500"

const viewBoxes: Readonly<Record<Framing, (state: PlaygroundState) => string>> = {
  stage: () => stageViewBox,
  figure: () => FIGURE_VIEW_BOX,
  portrait: (state) => portraitViewBox(state.look.hat)
}

export function renderScene(state: PlaygroundState, framing: Framing, uid: string): string {
  const animation = animationById(state.animation)
  const frame = { look: state.look, t: state.time, viewBox: viewBoxes[framing](state), uid }
  if (!state.rig.on) return animation.render(frame)

  return renderRig(frame, animation.rigPose(state.time), state.rig)
}
