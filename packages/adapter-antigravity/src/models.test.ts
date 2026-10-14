import { describe, expect, it } from "vitest"

import { configOptions, parseModels, resolveSelection } from "./models.js"

describe("agy model catalog", () => {
  it("groups the variants `agy models` lists under one model each", () => {
    const models = parseModels(
      [
        "Fetching available models...",
        "gemini-4-argon-high       Gemini 4 Argon (High)",
        "gemini-4-argon-low        Gemini 4 Argon (Low)",
        "gemini-3.8-flash-fast     Gemini 3.8 Flash (Fast)",
        "claude-opus-5-5-thinking  Claude Opus 5.5 (Thinking)",
        "gpt-oss-120b              GPT-OSS 120B",
        ""
      ].join("\n")
    )
    expect(models).toEqual([
      {
        id: "gemini-4-argon",
        name: "Gemini 4 Argon",
        variants: [
          { slug: "gemini-4-argon-high", tier: "high", label: "High" },
          { slug: "gemini-4-argon-low", tier: "low", label: "Low" }
        ]
      },
      {
        id: "gemini-3.8-flash",
        name: "Gemini 3.8 Flash",
        variants: [{ slug: "gemini-3.8-flash-fast", tier: "fast", label: "Fast" }]
      },
      {
        id: "claude-opus-5-5",
        name: "Claude Opus 5.5",
        variants: [{ slug: "claude-opus-5-5-thinking", tier: "thinking", label: "Thinking" }]
      },
      {
        id: "gpt-oss-120b",
        name: "GPT-OSS 120B",
        variants: [{ slug: "gpt-oss-120b", tier: undefined, label: undefined }]
      }
    ])
    // Without a medium tier, a model runs at its first listed one.
    expect(resolveSelection(models, {})!.variant.slug).toBe("gemini-4-argon-high")
  })

  it("keeps a slug whole when its tier isn't part of it", () => {
    expect(parseModels("argon-preview  Gemini 4 Argon (Preview Build)")).toEqual([
      {
        id: "argon-preview",
        name: "Gemini 4 Argon",
        variants: [{ slug: "argon-preview", tier: "preview-build", label: "Preview Build" }]
      }
    ])
  })

  it("offers a reasoning picker only for a model with several tiers", () => {
    const models = parseModels("gpt-oss-120b  GPT-OSS 120B\nflash-low  Flash (Low)")
    expect(configOptions(models, {}).map((option) => option.id)).toEqual(["model"])
    expect(configOptions(models, { modelId: "flash" }).map((option) => option.id)).toEqual([
      "model"
    ])
    expect(configOptions([], {})).toEqual([])
  })
})
