import { useEffect, useMemo, useRef, useState } from "react"

import { circleAvatar, displayScales, figureSide, sidebarFigure } from "./app-sizes.js"
import { Choice } from "./controls/choice.js"
import { drawAvatar, drawFigure, type PreviewDrawer } from "./preview-canvas.js"
import { renderScene } from "./scene.js"
import { backdrops, type Backdrop, type PlaygroundState } from "./state.js"
import { useThrottled } from "./use-throttled.js"

export interface PreviewsProps {
  readonly state: PlaygroundState
}

const appFramesPerSecond = 12
const magnifications = [1, 2, 4].map((zoom) => ({ id: String(zoom), title: `Zoom ${zoom}×` }))

export function Previews({ state }: PreviewsProps) {
  const shown = useThrottled(state, 1000 / appFramesPerSecond)
  const [zoom, setZoom] = useState("2")
  const figure = useMemo(() => renderScene(shown, "figure", "pf"), [shown])
  const portrait = useMemo(() => renderScene(shown, "portrait", "pp"), [shown])
  return (
    <section className="previews">
      <header>
        <h2>In the app</h2>
        <span className="hint">
          Sidebar figure ({sidebarFigure.slot}pt slot) and circle avatar ({circleAvatar.size}pt) at
          1×, 2× and 3×
        </span>
        <Choice label="" value={zoom} options={magnifications} onChange={setZoom} />
      </header>
      {backdrops.map((backdrop) => (
        <PreviewRow
          key={backdrop}
          backdrop={backdrop}
          figure={figure}
          portrait={portrait}
          zoom={Number(zoom)}
        />
      ))}
    </section>
  )
}

function PreviewRow({
  backdrop,
  figure,
  portrait,
  zoom
}: {
  readonly backdrop: Backdrop
  readonly figure: string
  readonly portrait: string
  readonly zoom: number
}) {
  return (
    <div className={`preview-row ${backdrop}`}>
      {displayScales.map((scale) => (
        <figure key={`figure${scale}`} className="preview">
          <div className="figure-box" style={{ width: figureSide * zoom }}>
            <PreviewCanvas
              svg={figure}
              scale={scale}
              points={figureSide}
              zoom={zoom}
              draw={drawFigure}
            />
            <div
              className="slot"
              style={{ width: sidebarFigure.slot * zoom, height: sidebarFigure.slot * zoom }}
            />
          </div>
          <figcaption>figure {scale}×</figcaption>
        </figure>
      ))}
      {displayScales.map((scale) => (
        <figure key={`avatar${scale}`} className="preview">
          <PreviewCanvas
            svg={portrait}
            scale={scale}
            points={circleAvatar.size}
            zoom={zoom}
            draw={drawAvatar}
          />
          <figcaption>avatar {scale}×</figcaption>
        </figure>
      ))}
    </div>
  )
}

function PreviewCanvas({
  svg,
  scale,
  points,
  zoom,
  draw
}: {
  readonly svg: string
  readonly scale: number
  readonly points: number
  readonly zoom: number
  readonly draw: PreviewDrawer
}) {
  const canvas = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    if (canvas.current) void draw(canvas.current, svg, scale)
  }, [svg, scale, draw])

  return <canvas ref={canvas} style={{ width: points * zoom, height: points * zoom }} />
}
