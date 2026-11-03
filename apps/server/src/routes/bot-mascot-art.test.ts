import { botMascotHats, type BotMascotHat } from "@codevisor/bot-mascot"
import sharp from "sharp"
import { describe, expect, it } from "vitest"

import { renderMascotStill } from "./bot-mascot-art.js"

interface OpaqueRows {
  readonly top: number
  readonly bottom: number
}

const hats: ReadonlyArray<BotMascotHat | "none"> = ["none", ...botMascotHats.map((hat) => hat.id)]

describe("bot mascot figure framing", () => {
  it("keeps every hat inside the headroom and stands every bot on the same ground line", async () => {
    const rows = await Promise.all(hats.map((hat) => opaqueRows(hat)))

    expect(rows.every((row) => row.top > 0)).toBe(true)
    expect(new Set(rows.map((row) => row.bottom)).size).toBe(1)
  })
})

const opaqueRows = async (hat: BotMascotHat | "none"): Promise<OpaqueRows> => {
  const art = await renderMascotStill({ color: "mint", hat, eyewear: "none" }, "figure")
  const { data, info } = await sharp(art.bytes)
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true })
  const opaque = (y: number): boolean =>
    Array.from({ length: info.width }, (_, x) => data[(y * info.width + x) * 4 + 3]!).some(
      (alpha) => alpha > 0
    )
  const ys = Array.from({ length: info.height }, (_, y) => y).filter(opaque)
  return { top: ys[0]!, bottom: ys.at(-1)! }
}
