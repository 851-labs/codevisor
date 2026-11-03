import { downloadPng, downloadSvg } from "./raster.js"
import { renderScene } from "./scene.js"
import { frameOf, type PlaygroundState } from "./state.js"
import type { LiveGaze } from "./use-gaze.js"

export interface ExportButtonsProps {
  readonly state: PlaygroundState
  readonly live: LiveGaze
}

const exportPixels = 1024

export function ExportButtons({ state, live }: ExportButtonsProps) {
  const name = `bot-mascot-${state.animation}-f${frameOf(state)}`
  const svg = () => renderScene({ ...state, showGaze: false }, "stage", "ex", live)
  return (
    <div className="exports">
      <button onClick={() => void downloadPng(svg(), exportPixels, name)}>Export PNG</button>
      <button onClick={() => downloadSvg(svg(), name)}>Export SVG</button>
    </div>
  )
}
