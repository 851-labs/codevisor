import { describe, expect, it } from "vitest"
import { setup } from "./test-support.js"

describe("CodexProvider", () => {
  it("normalizes malformed thread model ids before exposing config options", async () => {
    const { created } = await setup({ startModel: "gpt-5.2-codex\u001b[1m" })
    const options = created?.metadata.configOptions ?? []
    const modelOption = options.find((option) => option.id === "model")
    expect(modelOption?.currentValue).toBe("gpt-5.2-codex")
    const effortOption = options.find((option) => option.id === "effort")
    expect(effortOption?.currentValue).toBe("medium")
  })

  it("falls back unknown thread models to the first picker model at the highest effort", async () => {
    const { created } = await setup({ startModel: "not-in-picker" })
    const options = created?.metadata.configOptions ?? []
    const modelOption = options.find((option) => option.id === "model")
    expect(modelOption?.currentValue).toBe("gpt-5.2-codex")
    const effortOption = options.find((option) => option.id === "effort")
    expect(effortOption?.currentValue).toBe("xhigh")
  })
})
