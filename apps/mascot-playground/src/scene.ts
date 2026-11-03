import { FIGURE_VIEW_BOX, portraitViewBox } from "@codevisor/bot-mascot"

import { animationById } from "./animations.js"
import { renderRig } from "./arm-rig.js"
import type { PlaygroundState } from "./state.js"
import { noGaze, type LiveGaze } from "./use-gaze.js"

export type Framing = "stage" | "figure" | "portrait"

const stageViewBox = "0 0 500 500"

const viewBoxes: Readonly<Record<Framing, (state: PlaygroundState) => string>> = {
  stage: () => stageViewBox,
  figure: () => FIGURE_VIEW_BOX,
  portrait: (state) => portraitViewBox(state.look.hat)
}

export function renderScene(
  state: PlaygroundState,
  framing: Framing,
  uid: string,
  live: LiveGaze = noGaze
): string {
  const animation = animationById(state.animation)
  const frame = {
    look: state.look,
    t: state.time,
    viewBox: viewBoxes[framing](state),
    uid,
    gaze: live.gaze
  }
  if (state.rig.on) return renderRig(frame, animation.rigPose(state.time), state.rig)

  const svg = animation.render(frame)
  const marked = framing === "stage" && state.showGaze && animation.gazes
  return marked ? withGazeMarks(svg, live) : svg
}

function withGazeMarks(svg: string, live: LiveGaze): string {
  const marks = targetMark(live.pointer) + gazeMark(live)
  return svg.replace(/<\/svg>$/, `${marks}</svg>`)
}

function targetMark(pointer: LiveGaze["pointer"]): string {
  if (!pointer) return ""
  const [x, y] = pointer
  return `<g stroke="#ff2d8a" stroke-width="2.5" fill="none"><circle cx="${x}" cy="${y}" r="9"/><path d="M${x - 16} ${y}h32M${x} ${y - 16}v32"/></g>`
}

function gazeMark({ gaze }: LiveGaze): string {
  if (!gaze) return ""
  const opacity = (0.25 + 0.75 * (gaze.weight ?? 1)).toFixed(2)
  return `<circle cx="${gaze.x.toFixed(1)}" cy="${gaze.y.toFixed(1)}" r="6" fill="#00a2ff" opacity="${opacity}"/>`
}
