import type { Move, PlaygroundState } from "./state.js"

export interface AnimationPickerProps {
  readonly state: PlaygroundState
  readonly set: (patch: Partial<PlaygroundState>) => void
}

interface MoveButton {
  readonly id: Move
  readonly title: string
  readonly hint: string
}

const moveButtons: ReadonlyArray<MoveButton> = [
  { id: "idle", title: "Idle", hint: "Resting, breathing and looking around" },
  { id: "working", title: "Working", hint: "Reads a clipboard and flips the page" },
  { id: "calling", title: "Calling", hint: "Picks up the phone and talks" },
  { id: "sleeping", title: "Sleeping", hint: "Dozes off and breathes slowly, with z's" },
  { id: "hangUp", title: "Hang up", hint: "Says bye and puts the phone away" },
  { id: "angryHangUp", title: "Angry hang-up", hint: "Gets annoyed and throws the phone" }
]

const endsCall = (move: Move): boolean => move === "hangUp" || move === "angryHangUp"

export function AnimationPicker({ state, set }: AnimationPickerProps) {
  return (
    <div className="picker">
      <div className="moves">
        {moveButtons.map((move) => (
          <button
            key={move.id}
            className="move"
            aria-pressed={state.move === move.id}
            disabled={endsCall(move.id) && state.move !== "calling"}
            onClick={() => set({ move: move.id })}
          >
            <strong>{move.title}</strong>
            <span>
              {endsCall(move.id) && state.move !== "calling" ? "Start a call first" : move.hint}
            </span>
          </button>
        ))}
      </div>
      <div className="playback">
        <button className="primary" onClick={() => set({ playing: !state.playing })}>
          {state.playing ? "Pause" : "Play"}
        </button>
        <label className="pill-toggle">
          <input
            type="checkbox"
            checked={state.follow}
            onChange={(e) => set({ follow: e.target.checked })}
          />
          Follow my cursor
        </label>
        <span className="hint-text">He looks at your cursor while he's idle.</span>
      </div>
    </div>
  )
}
