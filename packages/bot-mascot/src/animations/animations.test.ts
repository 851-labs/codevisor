import { describe, expect, it } from "vitest"

import {
  CALLING_SWAP_LOOP,
  callingSwapPose,
  flipState,
  pageGrip,
  renderCallingSwap,
  renderContext,
  renderIdleWorking
} from "../index.js"

const hasArms = (svg: string): boolean => svg.includes('data-r="outline"')
const holdsPhone = (svg: string): boolean => svg.includes('data-r="hand"')
const flyingPhone = (svg: string): boolean =>
  /<\/g><g transform="matrix\([^)]+\)">[^]*<\/g><\/svg>$/.test(svg)

describe("Idle to Working and back", () => {
  it.each([
    [1, false],
    [3, true],
    [9, true],
    [13.2, false]
  ])("at %ss has arms: %s", (t, arms) => {
    expect(hasArms(renderIdleWorking(renderContext(), "sunny", t, "0 0 500 500", "w"))).toBe(arms)
  })

  it("keeps the arms in his body layer while one reaches behind the board", () => {
    const behind = renderIdleWorking(renderContext(), "sunny", 4.3, "0 0 500 500", "w", {
      mode: "working"
    })
    const between = renderIdleWorking(renderContext(), "sunny", 5.0, "0 0 500 500", "w", {
      mode: "working"
    })
    expect(behind).toMatch(/<g transform="[^"]+">[^]*<\/g><g data-r="fx">/)
    expect(between).toMatch(/<g transform="translate\(250 350\) scale/)
  })

  it("carries the page over and back with the right arm", () => {
    const layers: Array<string> = []
    for (let tt = 0; tt < 12; tt += 0.05) {
      const layer = flipState(tt).layer
      if (layer && layer !== layers[layers.length - 1]) layers.push(layer)
    }
    expect(layers).toEqual(["front", "behind", "between", "front", "between", "behind", "front"])
    expect(flipState(1).f).toBe(0)
    expect(flipState(4.3).f).toBe(1)
  })

  it("holds the page low on our side once it hangs down", () => {
    expect(pageGrip(0)[1]).toBeCloseTo(309 + 68, 1)
    expect(pageGrip(360)[1]).toBeCloseTo(309 + 0.46 * 68, 1)
    expect(pageGrip(90)[1]).toBeGreaterThan(309)
  })
})

const frame = (t: number, exit?: number): string =>
  renderCallingSwap(renderContext(), "sky", t, {
    uid: "c",
    pose: callingSwapPose(t),
    ...(exit === undefined ? {} : { exit })
  })

const observe = (svg: string) => ({
  flying: flyingPhone(svg),
  arms: hasArms(svg),
  holds: holdsPhone(svg)
})

describe("Calling with the arm rig", () => {
  it.each([
    [0.2, "the phone lies on the ground", { flying: true }],
    [0.3, "he reaches for it", { arms: true, holds: false }],
    [0.6, "he picks it up", { holds: true, flying: false }],
    [3, "he holds it on the call", { holds: true }],
    [6.7, "he still holds it as the call ends", { holds: true }],
    [7.1, "he throws it away", { flying: true, holds: false }],
    [7.4, "his arms follow through", { arms: true }],
    [CALLING_SWAP_LOOP - 0.1, "his arms are gone before the loop restarts", { arms: false }]
  ])("at %ss %s", (t, _, expected) => {
    expect(observe(frame(t))).toMatchObject(expected)
  })

  it.each([
    [3, 0.05, "right after the call", { holds: true, flying: true, arms: true }],
    [3, 0.4, "the phone is tucked away", { flying: false }],
    [3, 0.6, "his arms are gone", { arms: false }],
    [7.1, 0.1, "a thrown phone keeps flying", { flying: true }]
  ])("tucks the phone away when the call ends at %ss, exit %s: %s", (t, exit, _, expected) => {
    expect(observe(frame(t, exit))).toMatchObject(expected)
  })
})
