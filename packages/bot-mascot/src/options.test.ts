import { describe, expect, it } from "vitest"

import {
  botMascotColorRotation,
  botMascotColors,
  botMascotEyewear,
  botMascotHats,
  botMascotMakeup,
  botMascotMoodOptions,
  botMascotOutfits,
  botMascotSwatches,
  randomBotMascotConfig,
  renderBotMascotSvg,
  resolveConfig,
  riveValues
} from "./index.js"

const ids = (list: ReadonlyArray<{ readonly id: string }>): ReadonlyArray<string> =>
  list.map((o) => o.id)

const seeded = (seed: number): (() => number) => {
  let s = seed
  return () => {
    s = (s * 1664525 + 1013904223) % 4294967296
    return s / 4294967296
  }
}

describe("bot mascot options", () => {
  it("lists the colors, hats, eyewear, outfits, makeup and moods it can draw", () => {
    expect(ids(botMascotColors)).toEqual([
      "ruby",
      "tomato",
      "tangerine",
      "sunny",
      "lime",
      "clover",
      "mint",
      "aqua",
      "sky",
      "electric",
      "lilac",
      "grape",
      "orchid",
      "bubblegum",
      "dream",
      "cocoa",
      "slate",
      "classic"
    ])
    expect(ids(botMascotHats)).toEqual([
      "beanie",
      "party",
      "propeller",
      "crown",
      "tophat",
      "pumpkin",
      "antennae",
      "wizard",
      "duck",
      "hardhat",
      "chef",
      "sailor",
      "cowboy",
      "conical",
      "straw",
      "floppy",
      "beret",
      "bucket"
    ])
    expect(ids(botMascotEyewear)).toEqual([
      "specs",
      "monocle",
      "goggles",
      "safety",
      "shades",
      "anaglyph",
      "welder",
      "nightVision"
    ])
    expect(ids(botMascotOutfits)).toEqual(["tie", "tutu", "dress", "robe", "suit", "overalls"])
    expect(ids(botMascotMakeup)).toEqual(["blush", "freckles", "lashes"])
    expect(ids(botMascotMoodOptions)).toEqual(["idle", "working", "calling"])
  })

  it("hands new bots every color once, starting with the first eight in their old order", () => {
    expect(botMascotColorRotation.toSorted()).toEqual(ids(botMascotColors).toSorted())
    expect(botMascotColorRotation.slice(0, 8)).toEqual([
      "sunny",
      "mint",
      "lilac",
      "bubblegum",
      "sky",
      "tomato",
      "electric",
      "dream"
    ])
  })

  it("gives every color its own Rive body", () => {
    const bodies = botMascotColors.map(({ id }) => riveValues({ color: id }).body0)

    expect(bodies.every((body) => typeof body === "string")).toBe(true)
    expect(new Set(bodies).size).toBe(botMascotColors.length)
  })

  it("titles every choice for a picker", () => {
    const all = [
      ...botMascotColors,
      ...botMascotHats,
      ...botMascotEyewear,
      ...botMascotOutfits,
      ...botMascotMakeup,
      ...botMascotMoodOptions
    ]
    expect(all.every((o) => o.title.length > 0)).toBe(true)
  })

  it("offers only swatches that exist, and Auto only where a designed default exists", () => {
    const known = new Set(ids(botMascotSwatches))
    for (const item of [
      ...botMascotHats,
      ...botMascotEyewear,
      ...botMascotOutfits,
      ...botMascotMakeup
    ]) {
      expect(item.swatches.every((s) => known.has(s))).toBe(true)
      if (item.hasAuto) expect(item.swatches.length).toBeGreaterThan(0)
    }
    expect(botMascotHats.find((h) => h.id === "beanie")).toMatchObject({ hasAuto: true })
    expect(botMascotHats.find((h) => h.id === "crown")).toMatchObject({
      swatches: [],
      hasAuto: false
    })
  })

  it.each(botMascotHats.filter((h) => h.swatches.length > 1))(
    "recolors the $id with its swatches",
    (hat) => {
      const first = hat.swatches[0]!
      const second = hat.swatches[1]!
      expect(renderBotMascotSvg({ hat: hat.id, hatColor: first })).not.toBe(
        renderBotMascotSvg({ hat: hat.id, hatColor: second })
      )
    }
  )

  it("ignores a swatch an item doesn't offer", () => {
    expect(renderBotMascotSvg({ outfit: "suit", outfitColor: "pink" })).toBe(
      renderBotMascotSvg({ outfit: "suit", outfitColor: "navy" })
    )
  })

  it("fills in the builder's defaults", () => {
    expect(resolveConfig({ makeup: { lashes: true } })).toEqual({
      color: "sunny",
      mood: "idle",
      hat: "none",
      hatColor: "auto",
      eyewear: "none",
      eyewearColor: "auto",
      outfit: "none",
      outfitColor: "auto",
      makeup: { blush: true, freckles: false, lashes: true },
      blushColor: "auto"
    })
  })

  it("randomizes into a new color and choices from the lists", () => {
    for (let seed = 1; seed <= 20; seed++) {
      const c = randomBotMascotConfig(seeded(seed), { color: "mint" })
      expect(c.color).not.toBe("mint")
      expect(["none", ...ids(botMascotHats)]).toContain(c.hat)
      expect(["none", ...ids(botMascotEyewear)]).toContain(c.eyewear)
      expect(["none", ...ids(botMascotOutfits)]).toContain(c.outfit)
      const hat = botMascotHats.find((h) => h.id === c.hat)
      expect(["auto", ...(hat?.swatches ?? [])]).toContain(c.hatColor)
    }
  })
})
