import { useCallback, useEffect, useRef, useState, type RefObject } from "react"

import { Advanced } from "./advanced.js"
import { AnimationPicker } from "./animation-picker.js"
import { InTheApp } from "./in-the-app.js"
import { OutfitPicker } from "./outfit-picker.js"
import { advanced } from "./playback.js"
import { RiveStage } from "./rive-stage.js"
import { Segmented } from "./segmented.js"
import type { PlaygroundState, View } from "./state.js"
import { stateFromSearch } from "./url-state.js"
import { useAnimationFrames } from "./use-animation-frames.js"
import { useGaze, type Point } from "./use-gaze.js"
import { useKeyboard } from "./use-keyboard.js"
import { useUrlSync } from "./use-url-sync.js"

type Change = (state: PlaygroundState) => PlaygroundState

const viewOptions: ReadonlyArray<{ id: View; title: string }> = [
  { id: "outfit", title: "Outfit" },
  { id: "animation", title: "Animation" }
]

export function App() {
  const [state, setState] = useState(() => stateFromSearch(location.search))
  const change = useCallback((next: Change) => setState(next), [])
  const set = (patch: Partial<PlaygroundState>) => change((s) => ({ ...s, ...patch }))
  const stage = useRef<HTMLDivElement>(null)
  useAnimationFrames(state.playing, (elapsed) => change((s) => advanced(s, elapsed)))
  useUrlSync(state)
  useKeyboard(change)
  const { live, point } = useGaze(true)
  useFollowCursor(state.follow, stage, point)
  useThemeAttribute(state.theme)

  const show = (view: View) => set({ view })

  return (
    <div className="app">
      <header className="hero">
        <h1>Bot mascot</h1>
        <Segmented value={state.view} options={viewOptions} onChange={show} />
        <button
          className="soft theme"
          onClick={() => set({ theme: state.theme === "light" ? "dark" : "light" })}
        >
          {state.theme === "light" ? "Dark mode" : "Light mode"}
        </button>
      </header>
      <main className={`studio ${state.view}`}>
        <section className="stage-area" ref={stage}>
          <div className="stage-card big">
            <div className="stage-art">
              <RiveStage
                look={state.look}
                gaze={live.gaze}
                move={state.move}
                playing={state.playing}
              />
            </div>
          </div>
          <InTheApp look={state.look} gaze={live.gaze} move={state.move} playing={state.playing} />
        </section>
        <aside className="controls-card">
          {state.view === "outfit" ? (
            <OutfitPicker look={state.look} onChange={(look) => set({ look })} />
          ) : null}
          {state.view === "animation" ? <AnimationPicker state={state} set={set} /> : null}
        </aside>
      </main>
      <Advanced state={state} change={change} live={live} onPointer={point} />
    </div>
  )
}

function useFollowCursor(
  on: boolean,
  stage: RefObject<HTMLDivElement | null>,
  point: (p: Point | null) => void
) {
  useEffect(() => {
    if (!on) {
      point(null)
      return undefined
    }
    const move = (event: PointerEvent) => point(stagePoint(stage.current, event))
    const leave = () => point(null)
    window.addEventListener("pointermove", move)
    document.documentElement.addEventListener("pointerleave", leave)
    return () => {
      window.removeEventListener("pointermove", move)
      document.documentElement.removeEventListener("pointerleave", leave)
    }
  }, [on, stage, point])
}

function stagePoint(area: HTMLDivElement | null, event: PointerEvent): Point | null {
  const art = area?.querySelector(".stage-art:last-of-type") ?? area?.querySelector(".stage-art")
  const rect = art?.getBoundingClientRect()
  if (!rect || rect.width === 0) return null
  return [
    ((event.clientX - rect.left) / rect.width) * 500,
    ((event.clientY - rect.top) / rect.height) * 500
  ]
}

function useThemeAttribute(theme: PlaygroundState["theme"]) {
  useEffect(() => {
    document.documentElement.dataset.theme = theme
  }, [theme])
}
