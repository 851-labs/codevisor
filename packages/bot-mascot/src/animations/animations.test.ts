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

describe("Calling with the arm rig", () => {
  it("reaches for the phone, holds it on the call and throws it away", () => {
    expect(holdsPhone(frame(0.3))).toBe(false)
    expect(flyingPhone(frame(0.3))).toBe(true)
    expect(holdsPhone(frame(0.75))).toBe(true)
    expect(holdsPhone(frame(3))).toBe(true)
    expect(holdsPhone(frame(6.7))).toBe(true)
    expect(flyingPhone(frame(7.1))).toBe(true)
    expect(holdsPhone(frame(7.1))).toBe(false)
    expect(hasArms(frame(7.4))).toBe(true)
    expect(hasArms(frame(CALLING_SWAP_LOOP - 0.1))).toBe(false)
  })

  it("lets go of the phone and tucks the arm away when the call ends", () => {
    expect(holdsPhone(frame(3, 0.05))).toBe(false)
    expect(flyingPhone(frame(3, 0.05))).toBe(true)
    expect(hasArms(frame(3, 0.05))).toBe(true)
    expect(flyingPhone(frame(3, 0.4))).toBe(false)
    expect(hasArms(frame(3, 0.6))).toBe(false)
    expect(flyingPhone(frame(7.1, 0.1))).toBe(true)
  })
})
