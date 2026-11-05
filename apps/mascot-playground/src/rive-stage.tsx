import {
  gazeOrigin,
  GAZE_RANGE,
  isRiveColor,
  renderContext,
  RIVE_STATE_MACHINE,
  riveValues,
  type BotMascotGaze,
  type ResolvedBotMascotConfig
} from "@codevisor/bot-mascot"
import riveUrl from "@codevisor/bot-mascot/rive/mascot.riv?url"
import { Alignment, Fit, Layout, Rive, type ViewModelInstance } from "@rive-app/canvas"
import { useEffect, useRef, useState, type CSSProperties } from "react"

export interface Framing {
  readonly x: number
  readonly y: number
  readonly side: number
}

export type RiveMove = "idle" | "working" | "calling" | "hangUp" | "angryHangUp"

export interface RiveStageProps {
  readonly look: ResolvedBotMascotConfig
  readonly gaze: BotMascotGaze | null
  readonly move?: RiveMove
  readonly playing: boolean
  readonly size?: number
  readonly framing?: Framing
}

const ARTBOARD_SIDE = 500
const origin = gazeOrigin(renderContext().body)

export function RiveStage({ look, gaze, move = "idle", playing, size, framing }: RiveStageProps) {
  const canvas = useRef<HTMLCanvasElement>(null)
  const [rive, setRive] = useState<Rive | null>(null)
  useEffect(() => riveOn(canvas.current, setRive), [])
  useEffect(
    () => apply(rive?.viewModelInstance ?? null, look, move === "idle" ? gaze : null),
    [rive, look, gaze, move]
  )
  useEffect(() => perform(rive?.viewModelInstance ?? null, move), [rive, move])
  useEffect(() => (playing ? rive?.play() : rive?.pause()), [rive, playing])
  if (!size || !framing) return <canvas ref={canvas} className="rive-canvas" />

  return (
    <div className="rive-window" style={{ width: size, height: size }}>
      <canvas ref={canvas} style={framed(size, framing)} />
    </div>
  )
}

function riveOn(
  canvas: HTMLCanvasElement | null,
  setRive: (rive: Rive | null) => void
): () => void {
  if (!canvas) return () => {}
  const rive: Rive = new Rive({
    src: riveUrl,
    canvas,
    stateMachine: RIVE_STATE_MACHINE,
    autoplay: true,
    autoBind: true,
    layout: new Layout({ fit: Fit.Contain, alignment: Alignment.Center }),
    onLoad: () => {
      rive.resizeDrawingSurfaceToCanvas()
      setRive(rive)
    }
  })
  return () => {
    setRive(null)
    rive.cleanup()
  }
}

function apply(
  vm: ViewModelInstance | null,
  look: ResolvedBotMascotConfig,
  gaze: BotMascotGaze | null
) {
  if (!vm) return
  const props = boundTo(vm)
  for (const [path, value] of Object.entries(riveValues(look))) props.set(path, value)
  props.set("gazeX", gaze ? Math.tanh((gaze.x - origin[0]) / GAZE_RANGE.reachX) : 0)
  props.set("gazeY", gaze ? Math.tanh((gaze.y - origin[1]) / GAZE_RANGE.reachY) : 0)
  props.set("gazeWeight", gaze ? (gaze.weight ?? 1) : 0)
}

function perform(vm: ViewModelInstance | null, move: RiveMove) {
  if (!vm) return
  const props = boundTo(vm)
  if (move === "hangUp" || move === "angryHangUp") {
    props.fire(move)
    props.set("mode", "idle")
    return
  }
  props.set("mode", move)
}

interface Bound {
  readonly set: (path: string, value: string | number) => void
  readonly fire: (path: string) => void
}

type Handle =
  | ReturnType<ViewModelInstance["number"]>
  | ReturnType<ViewModelInstance["color"]>
  | ReturnType<ViewModelInstance["enum"]>
  | ReturnType<ViewModelInstance["trigger"]>

const bindings = new WeakMap<ViewModelInstance, Bound>()

function boundTo(vm: ViewModelInstance): Bound {
  const known = bindings.get(vm)
  if (known) return known
  const bound = binding(vm)
  bindings.set(vm, bound)
  return bound
}

function binding(vm: ViewModelInstance): Bound {
  const handles = new Map<string, Handle>()
  const written = new Map<string, string | number>()
  const handle = (path: string, open: () => Handle): Handle => {
    if (!handles.has(path)) handles.set(path, open())
    return handles.get(path) ?? null
  }
  return {
    set: (path, value) => {
      if (written.get(path) === value) return
      written.set(path, value)
      write(vm, path, value, handle)
    },
    fire: (path) => {
      const trigger = handle(path, () => vm.trigger(path))
      if (trigger && "trigger" in trigger) trigger.trigger()
    }
  }
}

function write(
  vm: ViewModelInstance,
  path: string,
  value: string | number,
  handle: (path: string, open: () => Handle) => Handle
) {
  if (typeof value === "number") {
    const number = handle(path, () => vm.number(path))
    if (number && "value" in number) number.value = value
    return
  }
  if (isRiveColor(value)) {
    const color = handle(path, () => vm.color(path))
    if (color && "value" in color) color.value = Number.parseInt(value, 16) >>> 0
    return
  }
  const choice = handle(path, () => vm.enum(path))
  if (choice && "value" in choice) choice.value = value
}

const framed = (size: number, framing: Framing): CSSProperties => {
  const scale = size / framing.side
  return {
    position: "absolute",
    width: ARTBOARD_SIDE * scale,
    height: ARTBOARD_SIDE * scale,
    left: -framing.x * scale,
    top: -framing.y * scale
  }
}
