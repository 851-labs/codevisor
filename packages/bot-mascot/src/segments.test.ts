import { describe, expect, it } from "vitest"

import {
  botMascotRoute,
  botMascotSegmentIds,
  botMascotSegments,
  botMascotSequence,
  canFollow,
  IDLE_WORKING_TIMES,
  loopOf,
  renderBotMascotSegmentFrame,
  renderContext,
  renderIdleWorking,
  type BotMascotSegment,
  type BotMascotState,
  type SegmentFrame
} from "./index.js"

const viewBox = "0 0 500 500"
const draw = (frame: SegmentFrame): string =>
  renderBotMascotSegmentFrame({ frame, viewBox, uid: "s", color: "mint", hat: "beanie" })
const at = (segment: BotMascotSegment, t: number, clock = t): SegmentFrame => ({
  segment,
  t,
  clock,
  since: 0
})
const justBefore = (segment: BotMascotSegment): number => botMascotSegments[segment].seconds - 1e-9
const holdsPhone = (svg: string): boolean => svg.includes('data-r="hand"')
const zsWhileWaking = (t: number): number => sleepZs(draw({ ...at("wakeUp", t), since: 3 }))
const sleepZs = (svg: string): number => svg.match(/data-r="z"/g)?.length ?? 0
const flyingPhone = (svg: string): boolean =>
  /<\/g><g transform="matrix\([^)]+\)">[^]*<\/g><\/svg>$/.test(svg)

const states: ReadonlyArray<BotMascotState> = ["idle", "calling", "working", "sleeping"]

describe("mascot segments", () => {
  it("routes every request through idle", () => {
    expect(botMascotRoute("idle", "calling")).toEqual(["pickUp", "calling"])
    expect(botMascotRoute("calling", "hangUp")).toEqual(["hangUp", "idle"])
    expect(botMascotRoute("calling", "angryHangUp")).toEqual(["angryHangUp", "idle"])
    expect(botMascotRoute("working", "calling")).toEqual(["stopWorking", "pickUp", "calling"])
    expect(botMascotRoute("calling", "working")).toEqual(["hangUp", "startWorking", "working"])
    expect(botMascotRoute("working", "hangUp")).toEqual(["working"])
    expect(botMascotRoute("idle", "idle")).toEqual(["idle"])
  })

  it.each(states)("chains every route from %s into segments that can follow each other", (from) => {
    for (const request of [
      "idle",
      "calling",
      "working",
      "sleeping",
      "hangUp",
      "angryHangUp"
    ] as const) {
      const chain = [loopOf(from), ...botMascotRoute(from, request)]
      expect(() => botMascotSequence(chain.map((segment) => ({ segment })))).not.toThrow()
    }
  })

  it("only lets a segment follow one that ends where it starts", () => {
    expect(canFollow("idle", "pickUp")).toBe(true)
    expect(canFollow("working", "pickUp")).toBe(false)
    expect(() => botMascotSequence([{ segment: "idle" }, { segment: "calling" }])).toThrow()
  })

  it("starts calling and working from the same idle frame", () => {
    const idle = draw(at("idle", 0))
    expect(draw(at("pickUp", 0))).toBe(idle)
    expect(draw(at("startWorking", 0))).toBe(idle)
  })

  it.each(botMascotSegmentIds.filter((id) => botMascotSegments[id].to === "idle"))(
    "lands %s on the idle frame it hands over to",
    (segment) => {
      const end = botMascotSegments[segment].seconds
      expect(draw(at(segment, justBefore(segment), 7 + end))).toBe(draw(at("idle", 0, 7 + end)))
    }
  )

  it("picks up into the call, loops it cleanly and ends it from the same frame", () => {
    const onTheLine = draw(at("calling", 0, 4))
    expect(draw(at("pickUp", justBefore("pickUp"), 4))).toBe(onTheLine)
    expect(draw(at("calling", justBefore("calling"), 4))).toBe(onTheLine)
    expect(draw(at("hangUp", 0, 4))).toBe(onTheLine)
    expect(draw(at("angryHangUp", 0, 4))).toBe(onTheLine)
  })

  it("puts the phone down on the ground and lets go on a normal hang-up", () => {
    expect(holdsPhone(draw(at("hangUp", 0.5)))).toBe(true)
    expect(holdsPhone(draw(at("hangUp", 1)))).toBe(false)
    expect(flyingPhone(draw(at("hangUp", 1)))).toBe(true)
    expect(flyingPhone(draw(at("hangUp", 1.9)))).toBe(false)
    expect(holdsPhone(draw(at("hangUp", 1.9)))).toBe(false)
  })

  it("throws the phone on an angry hang-up", () => {
    expect(holdsPhone(draw(at("angryHangUp", 4)))).toBe(true)
    expect(flyingPhone(draw(at("angryHangUp", 5.6)))).toBe(true)
  })

  it("eases out of the call when it ends mid-cycle", () => {
    const cut = 2 + botMascotSegments.pickUp.seconds + 2.5
    const sequence = botMascotSequence([
      { segment: "idle", seconds: 2 },
      { segment: "pickUp" },
      { segment: "calling", seconds: 2.5 },
      { segment: "hangUp" }
    ])
    expect(sequence.at(cut + 0.1).leftCallAt).toBeCloseTo(2.5, 10)
    expect(draw(sequence.at(cut))).toBe(draw(at("calling", 2.5, cut)))
    expect(draw(sequence.at(cut + 0.1))).not.toBe(draw(at("hangUp", 0.1, cut + 0.1)))
    expect(draw(sequence.at(cut + 0.4))).toBe(draw(at("hangUp", 0.4, cut + 0.4)))
  })

  it("hands a whole number of calls over without easing", () => {
    const sequence = botMascotSequence([
      { segment: "pickUp" },
      { segment: "calling", seconds: 2 * botMascotSegments.calling.seconds },
      { segment: "angryHangUp" }
    ])
    expect(sequence.at(sequence.seconds - 1).leftCallAt).toBeUndefined()
  })

  it("falls asleep from idle and wakes back up through idle", () => {
    expect(botMascotRoute("idle", "sleeping")).toEqual(["fallAsleep", "sleeping"])
    expect(botMascotRoute("sleeping", "calling")).toEqual(["wakeUp", "pickUp", "calling"])
    expect(draw(at("fallAsleep", 0))).toBe(draw(at("idle", 0)))
  })

  it("loops the sleep with the z's still floating", () => {
    const asleep = draw(at("sleeping", 0, 3))
    expect(draw(at("sleeping", justBefore("sleeping"), 3))).toBe(asleep)
    expect(sleepZs(asleep)).toBeGreaterThan(0)
    expect(sleepZs(draw(at("idle", 0)))).toBe(0)
  })

  it("lets the z's fade out as he wakes", () => {
    expect(zsWhileWaking(0.05)).toBeGreaterThan(0)
    expect(zsWhileWaking(0.5)).toBe(0)
  })

  const { in: start, out, end } = IDLE_WORKING_TIMES
  const idleWorking = botMascotSequence([
    { segment: "idle", seconds: start },
    { segment: "startWorking" },
    { segment: "working", seconds: out - start - botMascotSegments.startWorking.seconds },
    { segment: "stopWorking" },
    { segment: "idle", seconds: end - out - botMascotSegments.stopWorking.seconds }
  ])

  it("plays Idle → Working → Idle for as long as before", () => {
    expect(idleWorking.seconds).toBeCloseTo(end, 10)
  })

  it.each([1, 2.2, 4.3, 9, 11.5, 12.2])(
    "plays Idle → Working → Idle at %ss exactly as before",
    (t) => {
      const frame = renderBotMascotSegmentFrame({ frame: idleWorking.at(t), viewBox, uid: "w" })
      expect(frame).toBe(
        renderIdleWorking(renderContext({ idPrefix: "w" }), "sunny", t, viewBox, "w")
      )
    }
  )
})
