import { animations } from "./animations.js"
import { Choice } from "./controls/choice.js"
import { Toggle } from "./controls/toggle.js"
import { atFrame, frameCount, steppedFrames, toggledPlaying } from "./playback.js"
import { frameOf, frameRates, speeds, type PlaygroundState } from "./state.js"

type Change = (change: (state: PlaygroundState) => PlaygroundState) => void

export interface TransportProps {
  readonly state: PlaygroundState
  readonly change: Change
}

const rateOptions = frameRates.map((fps) => ({ id: String(fps), title: `${fps} fps` }))
const speedOptions = speeds.map((speed) => ({ id: String(speed), title: `${speed}×` }))

export function Transport({ state, change }: TransportProps) {
  const set = (patch: Partial<PlaygroundState>) => change((s) => ({ ...s, ...patch }))
  const frames = frameCount(state)
  return (
    <section className="transport">
      <div className="row">
        <Choice
          label="Animation"
          value={state.animation}
          options={animations}
          onChange={(animation) => set({ animation, time: 0, playing: true })}
        />
        <button onClick={() => change((s) => steppedFrames(s, -1))} title="Previous frame (←)">
          ◀︎
        </button>
        <button
          className="play"
          onClick={() => change(toggledPlaying)}
          title="Play or pause (space)"
        >
          {state.playing ? "Pause" : "Play"}
        </button>
        <button onClick={() => change((s) => steppedFrames(s, 1))} title="Next frame (→)">
          ▶︎
        </button>
        <output className="counter">
          frame {frameOf(state)} / {frames} · {state.time.toFixed(2)}s
        </output>
      </div>
      <input
        className="scrub"
        type="range"
        min={0}
        max={frames}
        step={1}
        value={frameOf(state)}
        onChange={(event) =>
          change((s) => ({ ...atFrame(s, Number(event.target.value)), playing: false }))
        }
      />
      <div className="row">
        <Choice
          label="Speed"
          value={String(state.speed)}
          options={speedOptions}
          onChange={(speed) => set({ speed: Number(speed) })}
        />
        <Choice
          label="Frame rate"
          value={String(state.fps)}
          options={rateOptions}
          onChange={(fps) => set({ fps: Number(fps) })}
        />
        <Toggle label="Loop" checked={state.loop} onChange={(loop) => set({ loop })} />
      </div>
    </section>
  )
}
