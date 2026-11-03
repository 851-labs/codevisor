import { useCallback, useState } from "react"

import { ArmPanel } from "./arm-panel.js"
import { Choice, titled } from "./controls/choice.js"
import { ExportButtons } from "./export-buttons.js"
import { LookPanel } from "./look-panel.js"
import { advanced } from "./playback.js"
import { Previews } from "./previews.js"
import { Stage } from "./stage.js"
import { backdrops, type PlaygroundState } from "./state.js"
import { Transport } from "./transport.js"
import { stateFromSearch } from "./url-state.js"
import { useAnimationFrames } from "./use-animation-frames.js"
import { useKeyboard } from "./use-keyboard.js"
import { useUrlSync } from "./use-url-sync.js"

type Change = (state: PlaygroundState) => PlaygroundState

export function App() {
  const [state, setState] = useState(() => stateFromSearch(location.search))
  const change = useCallback((next: Change) => setState(next), [])
  const set = (patch: Partial<PlaygroundState>) => change((s) => ({ ...s, ...patch }))
  useAnimationFrames(state.playing, (elapsed) => change((s) => advanced(s, elapsed)))
  useUrlSync(state)
  useKeyboard(change)

  return (
    <div className="app">
      <header className="top">
        <h1>Mascot playground</h1>
        <Choice
          label="Stage"
          value={state.backdrop}
          options={titled(backdrops)}
          onChange={(backdrop) => set({ backdrop })}
        />
        <ExportButtons state={state} />
        <button onClick={() => void navigator.clipboard.writeText(location.href)}>Copy link</button>
      </header>
      <main>
        <section className="stage-column">
          <Stage state={state} onRig={(rig) => set({ rig })} />
          <Transport state={state} change={change} />
          <Previews state={state} />
        </section>
        <aside>
          <LookPanel look={state.look} onChange={(look) => set({ look })} />
          <ArmPanel rig={state.rig} onChange={(rig) => set({ rig })} />
        </aside>
      </main>
    </div>
  )
}
