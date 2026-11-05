import { useState } from "react"

import { ArmPanel } from "./arm-panel.js"
import { Choice, titled } from "./controls/choice.js"
import { ExportButtons } from "./export-buttons.js"
import { Previews } from "./previews.js"
import { Stage } from "./stage.js"
import { backdrops, type PlaygroundState } from "./state.js"
import { Transport } from "./transport.js"
import type { LiveGaze, Point } from "./use-gaze.js"

type Change = (change: (state: PlaygroundState) => PlaygroundState) => void

export interface AdvancedProps {
  readonly state: PlaygroundState
  readonly change: Change
  readonly live: LiveGaze
  readonly onPointer: (pointer: Point | null) => void
}

export function Advanced(props: AdvancedProps) {
  const [open, setOpen] = useState(false)
  return (
    <details className="advanced" onToggle={(e) => setOpen(e.currentTarget.open)}>
      <summary>Advanced</summary>
      {open ? <AdvancedTools {...props} /> : null}
    </details>
  )
}

function AdvancedTools({ state, change, live, onPointer }: AdvancedProps) {
  const set = (patch: Partial<PlaygroundState>) => change((s) => ({ ...s, ...patch }))
  return (
    <>
      <p className="advanced-note">
        Developer tools for today's renderer: individual animation parts, frame stepping, the arm
        rig and its overlays, export, and shareable links.
      </p>
      <div className="advanced-tools">
        <Choice
          label="Stage"
          value={state.backdrop}
          options={titled(backdrops)}
          onChange={(backdrop) => set({ backdrop })}
        />
        <ExportButtons state={state} live={live} />
        <button onClick={() => void navigator.clipboard.writeText(location.href)}>Copy link</button>
      </div>
      <div className="advanced-grid">
        <section className="stage-column">
          <Stage state={state} live={live} onRig={(rig) => set({ rig })} onPointer={onPointer} />
          <Transport state={state} change={change} />
          <Previews state={state} live={live} />
        </section>
        <aside>
          <ArmPanel rig={state.rig} onChange={(rig) => set({ rig })} />
        </aside>
      </div>
    </>
  )
}
