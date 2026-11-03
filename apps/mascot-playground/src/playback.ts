import { animationById } from "./animations.js"
import { frameOf, type PlaygroundState } from "./state.js"

export function advanced(state: PlaygroundState, elapsedSeconds: number): PlaygroundState {
  const seconds = animationById(state.animation).seconds
  const time = state.time + elapsedSeconds * state.speed
  if (time < seconds) return { ...state, time }
  if (state.loop) return { ...state, time: time % seconds }

  return { ...state, time: seconds, playing: false }
}

export const steppedFrames = (state: PlaygroundState, frames: number): PlaygroundState => ({
  ...state,
  playing: false,
  time: clampedTime(state, (frameOf(state) + frames) / state.fps)
})

export const atFrame = (state: PlaygroundState, frame: number): PlaygroundState => ({
  ...state,
  time: clampedTime(state, frame / state.fps)
})

export const frameCount = (state: PlaygroundState): number =>
  Math.max(1, Math.round(animationById(state.animation).seconds * state.fps))

export function toggledPlaying(state: PlaygroundState): PlaygroundState {
  const atEnd = state.time >= animationById(state.animation).seconds
  return { ...state, playing: !state.playing, time: atEnd ? 0 : state.time }
}

const clampedTime = (state: PlaygroundState, time: number): number =>
  Math.min(animationById(state.animation).seconds, Math.max(0, time))
