import { describe, expect, it } from "vitest"

import {
  blendPoses,
  botMascotMoods,
  floatingHand,
  handPop,
  isBotMascotMood,
  palette,
  renderBotMascotFrame,
  renderContext,
  type BotMascotMood,
  type HandPose
} from "../index.js"

const draw = (mood: BotMascotMood, t: number): string =>
  renderBotMascotFrame(renderContext(), "sunny", botMascotMoods[mood].pose(t), { uid: "m" })

const effects = (svg: string): string => svg.slice(svg.indexOf('<g data-r="fx">'))

describe("moods", () => {
  it.each(["idle", "calling"] as const)("%s loops seamlessly", (mood) => {
    const m = botMascotMoods[mood]
    const a = m.pose(0.37)
    const b = m.pose(0.37 + (m.loop ?? 0))
    expect(b.tilt).toBeCloseTo(a.tilt ?? 0, 2)
    expect(b.face?.turn ?? 0).toBeCloseTo(a.face?.turn ?? 0, 2)
  })

  it("reads a clipboard and flips its page", () => {
    expect(effects(draw("working", 0.1))).not.toContain("#FBF8F1")
    expect(effects(draw("working", 1))).toContain("#B98048")
    expect(effects(draw("working", 6))).toContain("#FBF8F1")
    expect(effects(draw("working", 4.4 + 0.5))).toContain("#FBF8F1")
  })

  it("blinks through a change of eye", () => {
    const mad = botMascotMoods.calling.pose(6)
    const idle = botMascotMoods.idle.pose(0)
    const mid = blendPoses(idle, mad, 0.5)
    expect(mad.face?.mode).toBe("mad")
    expect(mid.face?.blink).toBeLessThan(0.2)
    expect(blendPoses(idle, mad, 0).tilt).toBeCloseTo(idle.tilt ?? 0, 10)
    expect(blendPoses(idle, mad, 1).tilt).toBeCloseTo(mad.tilt ?? 0, 10)
    expect(mid.fx?.every((f) => f.op <= 0.5)).toBe(true)
  })

  it("knows its moods", () => {
    expect(isBotMascotMood("calling")).toBe(true)
    expect(isBotMascotMood("dancing")).toBe(false)
  })
})

const handPoseNames: ReadonlyArray<HandPose> = [
  "open",
  "thumbsUp",
  "indexUp",
  "chin",
  "point",
  "typing"
]

describe("floating hands", () => {
  it.each(handPoseNames)("draws a %s hand with its own shade", (pose) => {
    const ctx = renderContext({ idPrefix: "h" })
    const svg = floatingHand(ctx, palette("mint"), {
      pose,
      x: 10,
      y: 20,
      rot: 30,
      s: 0.8,
      mirror: pose === "open"
    })
    expect(svg).toContain('<linearGradient id="hhd1g"')
    expect(svg).toContain('mask="url(#hhd1m)"')
  })

  it("pops a ring as a hand appears", () => {
    expect(handPop(palette("sunny"), 0, 0, 0)).toBe("")
    expect(handPop(palette("sunny"), 0, 0, 0.5)).toContain("<circle")
  })
})
