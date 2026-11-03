import { describe, expect, it } from "vitest"

import {
  BotMascotPlayer,
  GAZE_EASING,
  GAZE_RANGE,
  gazeFollower,
  gazeOrigin,
  idleAt,
  lookingAt,
  renderBotMascotSegmentFrame,
  renderContext,
  soloFrame,
  type BotMascotGaze,
  type BotMascotSegment
} from "../index.js"

const viewBox = "0 0 500 500"
const origin = gazeOrigin(renderContext().body)
const draw = (segment: BotMascotSegment, t: number, gaze?: BotMascotGaze | null): string =>
  renderBotMascotSegmentFrame({
    frame: soloFrame(segment, t),
    viewBox,
    uid: "g",
    ...(gaze === undefined ? {} : { gaze })
  })
const look = (gaze: BotMascotGaze) => lookingAt(idleAt(2.2), gaze, origin).face ?? {}

const follow = (
  follower: ReturnType<typeof gazeFollower>,
  target: readonly [number, number] | null,
  seconds: number
): BotMascotGaze | null => {
  let gaze: BotMascotGaze | null = null
  for (let t = 0; t < seconds; t += 1 / 60) gaze = follower.step(target, 1 / 60)
  return gaze
}

describe("looking at a point", () => {
  it("draws idle exactly as before without a gaze", () => {
    expect(draw("idle", 3.1, null)).toBe(draw("idle", 3.1))
    expect(draw("idle", 3.1, { x: 600, y: 0, weight: 0 })).toBe(draw("idle", 3.1))
  })

  it("turns his eye toward the point and leans a little", () => {
    const right = lookingAt(idleAt(2.2), { x: origin[0] + 120, y: origin[1] }, origin)
    expect(right.face?.turn).toBeGreaterThan(0.4)
    expect(right.tilt).toBeGreaterThan(1)
    expect(look({ x: origin[0], y: origin[1] - 120 }).up).toBeLessThan(-0.3)
    expect(look({ x: origin[0], y: origin[1] + 120 }).up).toBeGreaterThan(0.25)
  })

  it("keeps a far point within his range", () => {
    expect(look({ x: 5000, y: origin[1] }).turn).toBeLessThanOrEqual(GAZE_RANGE.turn)
    expect(look({ x: origin[0], y: -5000 }).up).toBeGreaterThanOrEqual(-GAZE_RANGE.up)
  })

  it("keeps blinking while he looks", () => {
    expect(lookingAt(idleAt(1.47), { x: 400, y: 100 }, origin).face?.blink).toBeLessThan(0.5)
  })

  it.each(["pickUp", "startWorking"] as const)(
    "leaves for %s from the frame he was looking from",
    (segment) => {
      const gaze = { x: 380, y: 150 }
      expect(draw(segment, 0, gaze)).toBe(draw("idle", 0, gaze))
      expect(draw(segment, 0, gaze)).not.toBe(draw("idle", 0))
    }
  )
})

describe("following a target", () => {
  it("eases toward a target instead of jumping to it", () => {
    const follower = gazeFollower(origin)
    const first = follower.step([400, 150], 1 / 60)
    expect(first?.weight).toBeLessThan(0.05)
    const settled = follow(follower, [400, 150], 1)
    expect(settled?.weight).toBeGreaterThan(0.95)
    expect(settled?.x).toBeCloseTo(400, 0)
  })

  it("drifts back to the centre once the target goes away", () => {
    const follower = gazeFollower(origin)
    follow(follower, [400, 150], 1)
    const drifting = follower.step(null, 0.5)
    expect(drifting?.weight).toBeGreaterThan(0.3)
    expect(follow(follower, null, 6)).toBeNull()
  })

  it("lets a target go after it stops moving, until it moves again", () => {
    const follower = gazeFollower(origin)
    follow(follower, [400, 150], GAZE_EASING.stillAfter + 6)
    expect(follower.step([400, 150], 1 / 60)).toBeNull()
    expect(follow(follower, [420, 160], 1)?.weight).toBeGreaterThan(0.9)
  })
})

describe("BotMascotPlayer gaze", () => {
  it("looks at the pointer while idle and settles back once it's gone", () => {
    const player = new BotMascotPlayer({ now: 0 })
    const still = new BotMascotPlayer({ now: 0 })
    player.lookAt([420, 120])
    for (const now of [0, 100, 400, 800, 1200]) player.frame(now)
    expect(player.frame(1200)).not.toBe(still.frame(1200))
    player.lookAt(null)
    for (let now = 1300; now < 9000; now += 250) player.frame(now)
    expect(player.frame(9000)).toBe(still.frame(9000))
  })
})
