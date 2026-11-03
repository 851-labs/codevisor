import { describe, expect, it } from "vitest"

import { BotMascotPlayer, renderBotMascotSvg } from "./index.js"

const FRAME_MS = 1000 / 30

const run = (player: BotMascotPlayer, from: number, to: number): string => {
  let svg = ""
  for (let now = from; now <= to; now += FRAME_MS) svg = player.frame(now)
  return svg
}

const hatOffset = (svg: string): number =>
  Number(/data-r="hat" transform="[^"]*translate\(0 ([-\d.]+)\)/.exec(svg)?.[1])

const opacity = (svg: string): number =>
  Number(/data-r="wear" [^>]*opacity="([\d.]+)"/.exec(svg)?.[1])

const flyingPhone = (svg: string): boolean =>
  /<\/g><g transform="matrix\([^)]+\)">[^]*<\/g><\/svg>$/.test(svg)

const tip = (svg: string): string => /<g id="[^"]*dt0"><path d="([^"]+)"/.exec(svg)?.[1] ?? ""

describe("BotMascotPlayer", () => {
  it("idles without arms", () => {
    const player = new BotMascotPlayer({ now: 0 })
    player.frame(0)
    expect(player.frame(1500)).not.toContain('data-r="outline"')
  })

  it("grows arms when it starts working and tucks them away after", () => {
    const player = new BotMascotPlayer({ now: 0 })
    player.frame(0)
    player.update({ mood: "working" }, 500)
    player.frame(500)
    expect(player.frame(1400)).toContain('data-r="outline"')
    player.update({ mood: "idle" }, 1500)
    player.frame(1600)
    expect(player.frame(3000)).not.toContain('data-r="outline"')
  })

  it("picks up the phone on a call and hangs up calmly when the call ends", () => {
    const player = new BotMascotPlayer({ now: 0, config: { mood: "calling" } })
    player.frame(0)
    expect(player.frame(2000)).toContain('data-r="hand"')
    player.update({ mood: "idle" }, 2000)
    player.frame(2050)
    expect(player.frame(2700)).toContain('data-r="hand"')
    expect(player.frame(4400)).not.toContain('data-r="hand"')
  })

  it("throws the phone when asked to hang up angrily", () => {
    const player = new BotMascotPlayer({ now: 0 })
    player.request("calling", 0)
    player.frame(0)
    expect(player.frame(3000)).toContain('data-r="hand"')
    player.request("angryHangUp", 3000)
    player.frame(3000 + FRAME_MS)
    expect(flyingPhone(player.frame(8600))).toBe(true)
    expect(player.frame(11000)).not.toContain('data-r="hand"')
    expect(player.current.mood).toBe("idle")
  })

  it("ignores a hang-up when there's no call", () => {
    const player = new BotMascotPlayer({ now: 0, config: { mood: "working" } })
    player.request("angryHangUp", 100)
    expect(player.current.mood).toBe("working")
  })

  it("drops a new hat onto his head, where it settles", () => {
    const player = new BotMascotPlayer({ now: 0 })
    run(player, 0, 300)
    player.update({ hat: "tophat" }, 300)
    expect(hatOffset(player.frame(300 + FRAME_MS))).toBeLessThan(-100)
    expect(Math.abs(hatOffset(run(player, 300 + 2 * FRAME_MS, 3300)))).toBeLessThan(1)
  })

  it("fades new clothes in", () => {
    const player = new BotMascotPlayer({ now: 0 })
    player.frame(0)
    player.update({ outfit: "suit" }, 300)
    expect(opacity(player.frame(300 + FRAME_MS))).toBeLessThan(0.2)
    expect(opacity(player.frame(1000))).toBe(1)
  })

  it("swings a tie as he moves", () => {
    const player = new BotMascotPlayer({ now: 0, config: { outfit: "tie" } })
    const early = tip(run(player, 0, 1000))
    expect(tip(run(player, 1000 + FRAME_MS, 2500))).not.toBe(early)
  })

  it("holds the still frames when motion is reduced", () => {
    const player = new BotMascotPlayer({
      now: 0,
      reducedMotion: true,
      config: { mood: "working", hat: "beanie" }
    })
    expect(player.frame(5000)).toBe(
      renderBotMascotSvg({ mood: "working", hat: "beanie", uid: "live" })
    )
  })
})
