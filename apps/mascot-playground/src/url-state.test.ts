import { describe, expect, it } from "vitest"

import { defaultState, withArm, type PlaygroundState } from "./state.js"
import { stateFromSearch, stateToSearch } from "./url-state.js"

const linked: PlaygroundState = {
  ...defaultState,
  look: { ...defaultState.look, color: "mint", hat: "beanie", hatColor: "red" },
  animation: "calling",
  playing: false,
  time: 42 / 60,
  rig: withArm({ ...defaultState.rig, on: true }, "right", { on: true, x: 440, y: 260 })
}

describe("shared playground links", () => {
  it("bring back the outfit, animation, frame and arm", () => {
    expect(stateFromSearch(stateToSearch(linked))).toEqual(linked)
  })

  it("keep the defaults out of the link", () => {
    expect(stateToSearch(defaultState)).toBe("")
  })

  it("open Idle for a link to a removed sequence preset", () => {
    for (const preset of ["call-hang-up", "call-angry", "idle-working"])
      expect(stateFromSearch(`animation=${preset}`).animation).toBe("idle")
  })

  it("ignore values the mascot doesn't have", () => {
    const state = stateFromSearch("look.color=plaid&animation=sleepy&look.hat=sombrero&fps=7")

    expect(state.look.color).toBe(defaultState.look.color)
    expect(state.look.hat).toBe("none")
    expect(state.animation).toBe(defaultState.animation)
    expect(state.fps).toBe(defaultState.fps)
  })
})
