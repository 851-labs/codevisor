import { describe, expect, it } from "vitest"

import type { Point } from "../geometry/math.js"
import {
  ARM_LENGTH,
  drawFlippersInBody,
  drawFlippersOver,
  drawRig,
  edgeX,
  idleAt,
  outlinePoly,
  palette,
  phoneProp,
  poseArm,
  renderBotMascotFrame,
  renderContext,
  restingArm,
  signedDistance,
  spineTip,
  type FlipperArm,
  type Torso
} from "../index.js"

const ctx = renderContext()
const svg = renderBotMascotFrame(ctx, "sunny", idleAt(0.5), { uid: "a" })
const body = /data-r="body" d="([^"]+)"/.exec(svg)![1]!
const torso: Torso = { d: body, shoulderY: ctx.body.shoulderY }
const MEDIUM = 2.7 * ARM_LENGTH

const targets: ReadonlyArray<Point> = [
  [430, 300],
  [400, 180],
  [330, 120],
  [250, 150],
  [160, 330],
  [300, 470],
  [420, 420],
  [70, 280],
  [250, 260]
]

const distance = (a: Point, b: Point): number => Math.hypot(a[0] - b[0], a[1] - b[1])

describe("the arm rig", () => {
  it.each(targets)("puts a fully grown arm's tip on (%d, %d) from either shoulder", (x, y) => {
    for (const side of [1, -1]) {
      const posed = poseArm(torso, { side, target: [x, y] })!
      const shoulder: Point = [edgeX(body, ctx.body.shoulderY, side), ctx.body.shoulderY]
      if (distance(shoulder, [x, y]) > MEDIUM + 20)
        expect(distance(spineTip(posed.arm!).tip, [x, y])).toBeLessThan(1)
      expect(posed.tip).toEqual(spineTip(posed.arm!).tip)
    }
  })

  it("points a short reach at its target with the same arm, shorter", () => {
    const posed = poseArm(torso, { side: 1, target: [360, 300] })!
    const full = poseArm(torso, { side: 1, target: [480, 300] })!
    expect(posed.arm!.L).toBeLessThan(full.arm!.L)
    const tip = spineTip(posed.arm!).tip
    const from = posed.arm!.R
    const along =
      Math.atan2(tip[1] - from[1], tip[0] - from[0]) - Math.atan2(300 - from[1], 360 - from[0])
    expect(Math.abs(along)).toBeLessThan(0.01)
  })

  it("grows out of the same shoulder opening", () => {
    const small = poseArm(torso, { side: 1, grow: 0.3, target: [430, 300] })!
    const full = poseArm(torso, { side: 1, grow: 1, target: [430, 300] })!
    expect(small.arm!.R).toEqual(full.arm!.R)
    expect(small.arm!.scale).toBeLessThan(1)
    expect(poseArm(torso, { side: 1, grow: 0, target: [430, 300] })).toBeNull()
  })

  it("rests at the bud's angle and breathes with him", () => {
    expect(poseArm(torso, { side: 1, t: 0 })!.arm!.th).not.toBe(
      poseArm(torso, { side: 1, t: 0.6 })!.arm!.th
    )
  })

  it("follows a fixed curl when given one", () => {
    const curled = poseArm(torso, { side: 1, target: [430, 300], curl: 60 })!
    const free = poseArm(torso, { side: 1, target: [430, 300] })!
    expect(distance(spineTip(curled.arm!).tip, [430, 300])).toBeLessThan(1)
    expect(curled.arm!.turn(1) - curled.arm!.turn(0)).toBeCloseTo(60, 5)
    expect(curled.arm!.th).not.toBeCloseTo(free.arm!.th, 1)
  })

  it("closes his hand round a held phone at the tip", () => {
    const phone = phoneProp("sunny")
    const posed = poseArm(torso, { side: 1, target: [380, 260], grip: phone })!
    expect(posed.prop?.svg).toBe(phone.svg)
    expect(posed.over).toBeGreaterThan(0)
    const drawn = drawRig(ctx, svg, [posed], { pal: "sunny", pose: idleAt(0.5) })
    expect(drawn).toContain('data-r="hand"')
    expect(drawn).toContain("matrix(")
  })

  it("wraps a phone's silhouette a little outside its handle", () => {
    const phone = phoneProp("mint")
    expect(phone.sil.length).toBeGreaterThan(100)
    expect(phone.scale).toBeCloseTo(1.15, 3)
  })

  it("joins the arm and his body into one outline", () => {
    const drawn = drawRig(ctx, svg, [poseArm(torso, { side: -1, target: [90, 260] })!], {
      pal: "sunny",
      pose: idleAt(0.5)
    })
    expect(drawn.match(/data-r="outline"/g)).toHaveLength(1)
    expect(drawn).toContain('<path data-r="body" d="')
  })

  it("gives a sleeved outfit's arms their sleeves", () => {
    const pose = { ...idleAt(0.5), wear: { outfit: "robe" } }
    const robed = renderBotMascotFrame(ctx, "sunny", pose, { uid: "r" })
    const robeBody = /data-r="body" d="([^"]+)"/.exec(robed)![1]!
    const arm = poseArm(
      { d: robeBody, shoulderY: ctx.body.shoulderY },
      { side: 1, target: [430, 330] }
    )!
    const drawn = drawRig(ctx, robed, [arm], { pal: "sunny", pose })
    expect(drawn).toContain('fill="#8B5CF6" mask="url(#rgrsm)"')
  })
})

const flipperArms: ReadonlyArray<Partial<FlipperArm>> = [
  {},
  { theta: 60, shaft: 50 },
  { phi: 90, rho: 16, sigma: 1 },
  { path: { L: 80, turn: (u) => 40 * u * u } },
  {
    curve: [
      [300, 340],
      [310, 380],
      [270, 390]
    ]
  },
  { bend: (s) => 3 * Math.sin(s / 8) },
  { front: true, softRoot: true, rootIn: 10 },
  { rigid: false, even: false, thick: 1.3, filletB: 9 }
]

describe("the flipper study", () => {
  it.each(flipperArms)("starts each flipper on his outline: %o", (overrides) => {
    for (const side of [1, -1]) {
      const arm = restingArm(ctx.body, side, overrides)
      const over = drawFlippersOver(svg, palette("sunny"), [arm])
      const inBody = drawFlippersInBody(svg, palette("sunny"), [arm])
      const join = /<clipPath id="m[ab]0j"><circle cx="([\d.-]+)" cy="([\d.-]+)"/
      for (const drawn of [over, inBody]) {
        const [, x, y] = join.exec(drawn)!
        const fromOutline = Math.abs(signedDistance(outlinePoly(body), [Number(x), Number(y)]).d)
        expect(fromOutline).toBeLessThan(overrides.rootIn ? 14 : 3)
      }
    }
  })
})
