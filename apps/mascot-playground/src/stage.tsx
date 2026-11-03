import { useEffect, useMemo, useRef, type PointerEvent } from "react"

import { renderScene } from "./scene.js"
import { withArm, type ArmSide, type PlaygroundState, type RigControls } from "./state.js"
import type { LiveGaze, Point } from "./use-gaze.js"

export interface StageProps {
  readonly state: PlaygroundState
  readonly live: LiveGaze
  readonly onRig: (rig: RigControls) => void
  readonly onPointer: (pointer: Point | null) => void
}

interface Drag {
  readonly side: ArmSide
}

const bodyCenterX = 250

export function Stage({ state, live, onRig, onPointer }: StageProps) {
  const host = useRef<HTMLDivElement>(null)
  const drag = useRef<Drag | null>(null)
  const svg = useMemo(() => renderScene(state, "stage", "st", live), [state, live])
  useEffect(() => forgetPointerOutside(host.current, onPointer), [onPointer])

  const aim = (event: PointerEvent<HTMLDivElement>, side: ArmSide) => {
    const target = bodyPoint(host.current, event)
    if (!target) return

    onRig(withArm({ ...state.rig, on: true }, side, { on: true, mode: "reach", ...target }))
  }

  const press = (event: PointerEvent<HTMLDivElement>) => {
    const target = bodyPoint(host.current, event)
    if (!state.rig.on || !target || event.button > 0) return

    event.currentTarget.setPointerCapture(event.pointerId)
    drag.current = { side: target.x < bodyCenterX ? "left" : "right" }
    aim(event, drag.current.side)
  }

  const move = (event: PointerEvent<HTMLDivElement>) => {
    onPointer(scenePoint(host.current, event))
    if (drag.current) aim(event, drag.current.side)
  }

  const release = () => {
    drag.current = null
  }

  return (
    <div
      ref={host}
      className={`stage ${state.backdrop}${state.rig.on ? " rigging" : ""}`}
      onPointerDown={press}
      onPointerMove={move}
      onPointerUp={release}
      onPointerCancel={release}
      dangerouslySetInnerHTML={{ __html: svg }}
    />
  )
}

function forgetPointerOutside(
  host: HTMLDivElement | null,
  onPointer: (pointer: Point | null) => void
): () => void {
  const away = (event: Event) => {
    if (!(event.target instanceof Node) || !host?.contains(event.target)) onPointer(null)
  }
  const gone = () => onPointer(null)
  window.addEventListener("pointermove", away)
  document.documentElement.addEventListener("pointerleave", gone)
  return () => {
    window.removeEventListener("pointermove", away)
    document.documentElement.removeEventListener("pointerleave", gone)
  }
}

function scenePoint(
  host: HTMLDivElement | null,
  event: PointerEvent<HTMLDivElement>
): Point | null {
  const matrix = host?.querySelector("svg")?.getScreenCTM()?.inverse()
  if (!matrix) return null

  const p = new DOMPoint(event.clientX, event.clientY).matrixTransform(matrix)
  return [p.x, p.y]
}

function bodyPoint(
  host: HTMLDivElement | null,
  event: PointerEvent<HTMLDivElement>
): { x: number; y: number } | null {
  const body = host?.querySelector<SVGGraphicsElement>('[data-r="tf"]')
  const matrix = body?.getScreenCTM()?.inverse()
  if (!matrix) return null

  const p = new DOMPoint(event.clientX, event.clientY).matrixTransform(matrix)
  return { x: Math.round(p.x), y: Math.round(p.y) }
}
