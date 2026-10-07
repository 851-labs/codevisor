import { describe, expect, it } from "vitest"

import { configOptions, parseModelValue, providerName } from "./models.js"

const gpt = { id: "gpt-6", name: "GPT-6", provider: "openai-codex" }
const spark = { id: "spark", provider: "openai-codex" }
const sonnet = { id: "sonnet", name: "Sonnet", provider: "anthropic" }

describe("Pi config options", () => {
  it("lists one provider's models flat, by name", () => {
    expect(
      configOptions({ models: [gpt, spark], model: spark, levels: [], level: undefined })
    ).toEqual([
      {
        id: "model",
        name: "Model",
        category: "model",
        currentValue: "openai-codex/spark",
        options: [
          { value: "openai-codex/gpt-6", name: "GPT-6" },
          { value: "openai-codex/spark", name: "spark" }
        ]
      }
    ])
  })

  it("groups several providers' models, and names thinking levels", () => {
    const [model, thinking] = configOptions({
      models: [gpt, sonnet],
      model: undefined,
      levels: ["off", "xhigh", "custom"],
      level: undefined
    })
    expect(model).toMatchObject({
      currentValue: "openai-codex/gpt-6",
      options: [
        { group: "openai-codex", name: "OpenAI Codex", options: [{ value: "openai-codex/gpt-6" }] },
        { group: "anthropic", name: "Anthropic", options: [{ value: "anthropic/sonnet" }] }
      ]
    })
    expect(thinking).toEqual({
      id: "thought_level",
      name: "Thinking",
      category: "thought_level",
      currentValue: "off",
      options: [
        { value: "off", name: "Off" },
        { value: "xhigh", name: "Extra High" },
        { value: "custom", name: "custom" }
      ]
    })
    expect(configOptions({ models: [], model: undefined, levels: ["low"], level: "low" })).toEqual([
      expect.objectContaining({ id: "thought_level", currentValue: "low" })
    ])
  })

  it("reads model values back, and names providers readably", () => {
    expect(parseModelValue("openai-codex/gpt-6/mini")).toEqual({
      provider: "openai-codex",
      modelId: "gpt-6/mini"
    })
    expect(parseModelValue("gpt-6")).toBeUndefined()
    expect(parseModelValue("/gpt-6")).toBeUndefined()
    expect(parseModelValue("openai/")).toBeUndefined()
    expect(
      ["xai", "github-copilot", "amazon_bedrock", "my--provider", "openrouter-api"].map(
        providerName
      )
    ).toEqual(["xAI", "GitHub Copilot", "Amazon Bedrock", "My Provider", "OpenRouter API"])
  })
})
