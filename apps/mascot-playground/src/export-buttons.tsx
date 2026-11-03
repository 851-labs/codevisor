import { downloadPng, downloadSvg } from "./raster.js"
import { renderScene } from "./scene.js"
import { frameOf, type PlaygroundState } from "./state.js"

export interface ExportButtonsProps {
  readonly state: PlaygroundState
}

const exportPixels = 1024

export function ExportButtons({ state }: ExportButtonsProps) {
  const name = `bot-mascot-${state.animation}-f${frameOf(state)}`
  const svg = () => renderScene(state, "stage", "ex")
  return (
    <div className="exports">
      <button onClick={() => void downloadPng(svg(), exportPixels, name)}>Export PNG</button>
      <button onClick={() => downloadSvg(svg(), name)}>Export SVG</button>
    </div>
  )
}
