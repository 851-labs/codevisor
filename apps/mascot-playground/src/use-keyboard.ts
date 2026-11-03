import { useEffect } from "react"

import { steppedFrames, toggledPlaying } from "./playback.js"
import type { PlaygroundState } from "./state.js"

type Change = (change: (state: PlaygroundState) => PlaygroundState) => void

const keyActions: Readonly<Record<string, (state: PlaygroundState) => PlaygroundState>> = {
  " ": toggledPlaying,
  ArrowLeft: (state) => steppedFrames(state, -1),
  ArrowRight: (state) => steppedFrames(state, 1)
}

export function useKeyboard(change: Change): void {
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const action = keyActions[event.key]
      if (!action || isEditing(event.target)) return

      event.preventDefault()
      change(action)
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [change])
}

const isEditing = (target: EventTarget | null): boolean =>
  target instanceof HTMLInputElement ||
  target instanceof HTMLSelectElement ||
  target instanceof HTMLButtonElement
