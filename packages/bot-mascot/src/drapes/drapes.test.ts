import { describe, expect, it } from "vitest"

import { palette } from "../color/palette.js"
import type { Point } from "../geometry/math.js"
import {
  dangle,
  DrapeSwings,
  drawRig,
  hatRider,
  idleAt,
  officialBody,
  outfitItems,
  poseArm,
  redrape,
  renderBotMascotFrame,
  renderContext,
  type BotMascotPose,
  type DrapeArm
} from "../index.js"

const STEP = 1 / 60

const settle = (pose: BotMascotPose, seconds: number): ReadonlyArray<Point> => {
  const ends = outfitItems.tutu.dangles.map(dangle)
  let tips: ReadonlyArray<Point> = []
  for (let t = 0; t < seconds; t += STEP) tips = ends.map((e) => e.step(officialBody, pose, STEP))
  return tips
}

const tieWith = (arms: ReadonlyArray<DrapeArm>, swings = new DrapeSwings(), now = 0) =>
  redrape(
    { body: officialBody, P: palette("sunny"), pose: { wear: { outfit: "tie" } }, uid: "d" },
    arms,
    swings,
    now
  )

const sweepingArm = (x: number): DrapeArm => ({
  key: 1,
  R: [300, 330],
  pts: Array.from({ length: 12 }, (_, i) => ({
    p: [300 - ((300 - x) * i) / 11, 360 + i * 2] as const,
    w: 14,
    root: i < 2
  })),
  tipOut: -20
})

describe("dangling hems", () => {
  it("hang plumb when he stands still", () => {
    const [left, right] = settle({}, 3)
    expect(left![1]).toBeGreaterThan(330)
    expect(right![1]).toBeGreaterThan(330)
    expect(left![0]).toBeLessThan(178)
    expect(right![0]).toBeGreaterThan(322)
  })

  it("swing when he hops and never fold up past his chest", () => {
    const ends = outfitItems.tie.dangles.map(dangle)
    let highest = Infinity
    for (let i = 0; i < 120; i++) {
      const hop = i < 20 ? -40 * i : 0
      const [tip] = ends.map((e) =>
        e.step(officialBody, { y: hop, lean: i % 2 ? 6 : -6 }, i % 9 ? STEP : 0.08)
      )
      highest = Math.min(highest, tip![1])
    }
    const knot = 330 + 16 - officialBody.zones!.neck
    expect(highest).toBeGreaterThan(knot)
  })

  it("start over after a reset", () => {
    const end = dangle(outfitItems.dress.dangles[0])
    const first = end.step(officialBody, {}, 0)
    end.step(officialBody, { y: 30 }, 0.05)
    end.reset()
    expect(end.step(officialBody, {}, 0)).toEqual(first)
  })
})

describe("a drape and an arm", () => {
  it("doesn't move when no arm is near", () => {
    const d = tieWith([])!
    expect(d.svg).toBeNull()
    expect(d.pieces.map((p) => p.hidden)).toEqual([false])
  })

  it("gives way to an arm reaching across it", () => {
    const d = tieWith([sweepingArm(200)])!
    expect(d.svg).not.toBeNull()
  })

  it("eases aside over time rather than jumping", () => {
    const swings = new DrapeSwings()
    tieWith([], swings, 0)
    const first = tieWith([sweepingArm(200)], swings, 16)!
    const later = tieWith([sweepingArm(200)], swings, 400)!
    expect(first.svg).not.toBe(later.svg)
  })

  it("is redrawn round the arm in a full frame", () => {
    const ctx = renderContext()
    const pose = { ...idleAt(0.5), wear: { outfit: "tie" } }
    const svg = renderBotMascotFrame(ctx, "sunny", pose, { uid: "t" })
    const body = /data-r="body" d="([^"]+)"/.exec(svg)![1]!
    const arm = poseArm(
      { d: body, shoulderY: ctx.body.shoulderY },
      { side: 1, target: [200, 370] }
    )!
    expect(drawRig(ctx, svg, [arm], { pal: "sunny", pose })).not.toBe(
      drawRig(ctx, svg, [], { pal: "sunny", pose })
    )
  })

  it("has nothing to redrape without a hanging drape", () => {
    expect(
      redrape(
        { body: officialBody, P: palette("sunny"), pose: {}, uid: "x" },
        [sweepingArm(200)],
        new DrapeSwings(),
        0
      )
    ).toBeNull()
  })
})

describe("a hat riding on his head", () => {
  it("falls, bounces and comes to rest", () => {
    const rider = hatRider()
    rider.drop(200)
    let motion = rider.step(officialBody, {}, 0)
    let maxImpact = 0
    for (let i = 0; i < 180; i++) {
      motion = rider.step(officialBody, {}, STEP)
      maxImpact = Math.max(maxImpact, motion.impact)
    }
    expect(maxImpact).toBeGreaterThan(0.3)
    expect(motion.falling).toBe(false)
    expect(Math.abs(motion.dy)).toBeLessThan(0.5)
  })

  it("lags behind a tilt and spins the propeller faster when he moves", () => {
    const rider = hatRider()
    rider.step(officialBody, {}, 0)
    const still = rider.step(officialBody, {}, STEP)
    const tilted = rider.step(officialBody, { tilt: 12, y: 20 }, STEP)
    expect(tilted.rot).toBeLessThan(0)
    expect(Math.abs(tilted.tipX)).toBeGreaterThan(Math.abs(still.tipX))
    rider.reset()
    expect(rider.step(officialBody, {}, 0).rot).toBe(0)
  })
})
