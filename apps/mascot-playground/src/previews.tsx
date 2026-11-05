import { useEffect, useMemo, useRef, useState } from "react"

import { circleAvatar, displayScales, figureSide, sidebarFigure } from "./app-sizes.js"
import { Choice } from "./controls/choice.js"
import { drawAvatar, drawFigure, type PreviewDrawer } from "./preview-canvas.js"
import { renderScene } from "./scene.js"
import { backdrops, type Backdrop, type PlaygroundState } from "./state.js"
import type { LiveGaze } from "./use-gaze.js"
import { useThrottled } from "./use-throttled.js"

export interface PreviewsProps {
  readonly state: PlaygroundState
  readonly live: LiveGaze
}

const appFramesPerSecond = 12
const magnifications = [1, 2, 4].map((zoom) => ({ id: String(zoom), title: `Zoom ${zoom}×` }))

export function Previews({ state, live }: PreviewsProps) {
  const latest = useMemo(() => ({ state, live }), [state, live])
  const shown = useThrottled(latest, 1000 / appFramesPerSecond)
  const [zoom, setZoom] = useState("2")
  const figure = useMemo(() => renderScene(shown.state, "figure", "pf", shown.live), [shown])
  const portrait = useMemo(() => renderScene(shown.state, "portrait", "pp", shown.live), [shown])
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

interface Painter {
  readonly paint: (canvas: HTMLCanvasElement, svg: string, scale: number) => void
  readonly stop: () => void
}

function latestOnly(draw: PreviewDrawer): Painter {
  let busy = false
  let stopped = false
  let next: Parameters<PreviewDrawer> | null = null
  const run = async (job: Parameters<PreviewDrawer>) => {
    busy = true
    await draw(...job).catch(() => undefined)
    busy = false
    const queued = next
    next = null
    if (queued && !stopped) void run(queued)
  }
  return {
    paint: (canvas, svg, scale) => {
      if (stopped) return
      if (busy) next = [canvas, svg, scale]
      else void run([canvas, svg, scale])
    },
    stop: () => {
      stopped = true
      next = null
    }
  }
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
  const painter = useMemo(() => latestOnly(draw), [draw])

  useEffect(() => {
    if (canvas.current) painter.paint(canvas.current, svg, scale)
  }, [painter, svg, scale])
  useEffect(() => () => painter.stop(), [painter])

  return <canvas ref={canvas} style={{ width: points * zoom, height: points * zoom }} />
}
