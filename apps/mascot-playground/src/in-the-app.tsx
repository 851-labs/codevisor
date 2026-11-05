import {
  FIGURE_VIEW_BOX,
  portraitViewBox,
  type BotMascotGaze,
  type ResolvedBotMascotConfig
} from "@codevisor/bot-mascot"

import { circleAvatar, figureSide } from "./app-sizes.js"
import { RiveStage, type Framing, type RiveMove } from "./rive-stage.js"

export interface InTheAppProps {
  readonly look: ResolvedBotMascotConfig
  readonly gaze: BotMascotGaze | null
  readonly move: RiveMove
  readonly playing: boolean
}

const framingOf = (viewBox: string): Framing => {
  const [x = 0, y = 0, side = 500] = viewBox.split(" ").map(Number)
  return { x, y, side }
}

export function InTheApp({ look, gaze, move, playing }: InTheAppProps) {
  return (
    <div className="in-the-app">
      <span className="caption">In the app, at real size</span>
      <figure>
        <RiveStage
          look={look}
          gaze={gaze}
          move={move}
          playing={playing}
          size={figureSide}
          framing={framingOf(FIGURE_VIEW_BOX)}
        />
        <figcaption>Sidebar</figcaption>
      </figure>
      <figure>
        <div
          className="avatar-circle"
          style={{ width: circleAvatar.size, height: circleAvatar.size }}
        >
          <RiveStage
            look={look}
            gaze={gaze}
            move={move}
            playing={playing}
            size={circleAvatar.size}
            framing={framingOf(portraitViewBox(look.hat))}
          />
        </div>
        <figcaption>Avatar</figcaption>
      </figure>
    </div>
  )
}
