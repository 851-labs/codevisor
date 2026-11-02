import { createHash } from "node:crypto"

import { describe, expect, it } from "vitest"

import { renderBotMascotSvg, type StaticRenderOptions } from "./index.js"

const canonicalIds = (svg: string): string => {
  const ids = new Map<string, string>()
  for (const m of svg.matchAll(/\bid="([^"]+)"/g))
    if (!ids.has(m[1]!)) ids.set(m[1]!, `ID${ids.size}`)
  const map = (id: string): string => ids.get(id) ?? `UNDEFINED(${id})`
  return svg
    .replace(/\bid="([^"]+)"/g, (_m, id: string) => `id="${map(id)}"`)
    .replace(/url\(#([^)]+)\)/g, (_m, id: string) => `url(#${map(id)})`)
    .replace(/href="#([^"]+)"/g, (_m, id: string) => `href="#${map(id)}"`)
}

const fingerprint = (svg: string): string =>
  createHash("sha256").update(canonicalIds(svg)).digest("hex").slice(0, 16)

const elementIds = (svg: string): ReadonlyArray<string> =>
  [...svg.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]!)

const isEmpty = (svg: string, role: string): boolean =>
  new RegExp(`data-r="${role}"[^>]*></g>`).test(svg)

const referenceRenders: ReadonlyArray<readonly [StaticRenderOptions, string]> = [
  [{}, "4096254dc10bd292"],
  [{ color: "mint", hat: "beanie", eyewear: "specs" }, "e2448a0f8fd425ba"],
  [{ color: "tomato", hat: "wizard", outfit: "robe", mood: "working" }, "6d75db3a8892eedf"],
  [
    { color: "dream", eyewear: "goggles", eyewearColor: "pink", outfit: "tie", mood: "calling" },
    "079e77587cf1cc55"
  ],
  [
    {
      color: "electric",
      hat: "crown",
      outfit: "overalls",
      makeup: { blush: true, freckles: true, lashes: true }
    },
    "27a21ffb6eddd48f"
  ],
  [{ color: "sky", hat: "propeller", outfit: "dress", mood: "working" }, "febb46ee75acbf07"],
  [
    { color: "lilac", hat: "tophat", outfit: "suit", outfitColor: "burgundy", mood: "calling" },
    "d247bec7081a4384"
  ],
  [
    { color: "bubblegum", hat: "party", eyewear: "monocle", outfit: "tutu", blushColor: "purple" },
    "929962880a863876"
  ],
  [{ color: "sunny", hat: "antennae", mood: "happy" }, "b990a95b905e2ff4"],
  [{ color: "mint", hat: "pumpkin", mood: "thinking" }, "b1736a3012895a36"],
  [{ color: "tomato", hat: "duck", mood: "sleepy", makeup: { blush: false } }, "3ada4b064fc78b55"],
  [{ color: "sky", mood: "sad", eyewear: "specs" }, "311936d1eb4644a7"],
  [{ color: "electric", mood: "surprised", outfit: "overalls" }, "104bc6caf0b4834c"]
]

describe("renderBotMascotSvg", () => {
  it.each(referenceRenders)("draws %j exactly as the reference builder did", (config, expected) => {
    expect(fingerprint(renderBotMascotSvg({ ...config, uid: "bm" }))).toBe(expected)
  })

  it("gives every element a unique id under the chosen uid", () => {
    const svg = renderBotMascotSvg({ hat: "beanie", outfit: "dress", mood: "working", uid: "card" })
    const ids = elementIds(svg)
    expect(new Set(ids).size).toBe(ids.length)
    expect(ids.every((id) => id.startsWith("card"))).toBe(true)
  })

  it("keeps two mascots on one page from sharing ids", () => {
    const a = elementIds(renderBotMascotSvg({ mood: "thinking", uid: "a" }))
    const b = new Set(elementIds(renderBotMascotSvg({ mood: "thinking", uid: "b" })))
    expect(a.filter((id) => b.has(id))).toEqual([])
  })

  it("paints the body in the chosen color's gradient", () => {
    const svg = renderBotMascotSvg({ color: "tomato" })
    expect(svg).toContain('stop-color="#FFA48C"')
    expect(svg).not.toContain('stop-color="#FFE27A"')
  })

  it("draws only what is worn", () => {
    const bare = renderBotMascotSvg()
    const dressed = renderBotMascotSvg({ hat: "crown", eyewear: "specs", outfit: "suit" })
    for (const role of ["hatc", "eyewear", "wear"]) {
      expect(isEmpty(bare, role)).toBe(true)
      expect(isEmpty(dressed, role)).toBe(false)
    }
  })

  it("frames a hat with room above the head", () => {
    expect(renderBotMascotSvg()).toContain('viewBox="49.745 39.490 400.510 400.510"')
    expect(renderBotMascotSvg({ hat: "wizard" })).toContain(
      'viewBox="31.745 1.490 436.510 436.510"'
    )
  })

  it("honours size, viewBox and backdrop", () => {
    const svg = renderBotMascotSvg({ size: 256, viewBox: "0 0 500 500", backdrop: "white" })
    const root = svg.slice(0, svg.indexOf(">"))
    expect(root).toContain('width="256" height="256"')
    expect(root).toContain('viewBox="0 0 500 500"')
    expect(svg).toContain('<rect width="500" height="500" fill="#FFFFFF"/>')
  })

  it("grows arms for working and calling but not idle", () => {
    expect(renderBotMascotSvg({ mood: "idle" })).not.toContain('data-r="outline"')
    expect(renderBotMascotSvg({ mood: "working" })).toContain('data-r="outline"')
    expect(renderBotMascotSvg({ mood: "calling" })).toContain('data-r="hand"')
  })

  it("draws the original, shorter body when zones are turned off", () => {
    const official = renderBotMascotSvg({ viewBox: "0 0 500 500" })
    const original = renderBotMascotSvg({ viewBox: "0 0 500 500", zones: null })
    expect(official).toContain('x1="0" y1="152.10"')
    expect(original).toContain('x1="0" y1="186"')
  })
})
