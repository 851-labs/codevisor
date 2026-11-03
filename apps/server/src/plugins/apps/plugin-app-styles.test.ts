import { describe, expect, it } from "vitest"

import { appHostStyles } from "./plugin-app-styles.js"

const tiers = ["primary", "secondary", "tertiary", "inverse", "ghost"]
const tones = ["info", "danger", "success", "warning", "disabled"]
const colorKeys = [
  ...["background", "text", "border"].flatMap((role) =>
    [...tiers, ...tones].map((tier) => `--color-${role}-${tier}`)
  ),
  ...["primary", "secondary", "inverse", "info", "danger", "success", "warning"].map(
    (tier) => `--color-ring-${tier}`
  )
]
const typeKeys = [
  ...["xs", "sm", "md", "lg"].map((size) => `text-${size}`),
  ...["xs", "sm", "md", "lg", "xl", "2xl", "3xl"].map((size) => `heading-${size}`)
].flatMap((name) => [`--font-${name}-size`, `--font-${name}-line-height`])
const standardKeys = [
  ...colorKeys,
  "--font-sans",
  "--font-mono",
  ...["normal", "medium", "semibold", "bold"].map((weight) => `--font-weight-${weight}`),
  ...typeKeys,
  ...["xs", "sm", "md", "lg", "xl", "full"].map((size) => `--border-radius-${size}`),
  "--border-width-regular",
  ...["hairline", "sm", "md", "lg"].map((size) => `--shadow-${size}`)
]

describe("plugin app host styles", () => {
  it("gives apps every standardized MCP Apps style variable", () => {
    expect(standardKeys).toHaveLength(76)
    for (const platform of ["desktop", "mobile"] as const) {
      expect(Object.keys(appHostStyles(platform).variables).toSorted()).toEqual(
        standardKeys.toSorted()
      )
    }
  })

  it("lets each color follow the app's light or dark theme", () => {
    const { variables } = appHostStyles("desktop")
    const themed = colorKeys.filter((key) => !key.endsWith("-ghost") || key.includes("text"))

    for (const key of themed) expect(variables[key]).toMatch(/^light-dark\(.+, .+\)$/)
    expect(variables["--shadow-md"]).toContain("light-dark(")
  })

  it("uses larger type on phones", () => {
    expect(appHostStyles("desktop").variables["--font-text-md-size"]).toBe("13px")
    expect(appHostStyles("mobile").variables["--font-text-md-size"]).toBe("17px")
  })
})
