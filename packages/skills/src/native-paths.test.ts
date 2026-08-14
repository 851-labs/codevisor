import { describe, expect, it } from "vitest"
import { resolveNativeConfigPath } from "./native-paths.js"

describe("resolveNativeConfigPath", () => {
  it("resolves ~/ paths against home", () => {
    expect(resolveNativeConfigPath("~/.claude/skills", { home: "/Users/u" })).toBe(
      "/Users/u/.claude/skills"
    )
  })

  it("honors CODEX_HOME for ~/.codex paths", () => {
    expect(
      resolveNativeConfigPath("~/.codex/skills", {
        env: { CODEX_HOME: "/opt/codex" },
        home: "/Users/u"
      })
    ).toBe("/opt/codex/skills")
  })

  it("ignores empty CODEX_HOME", () => {
    expect(
      resolveNativeConfigPath("~/.codex/skills", { env: { CODEX_HOME: "" }, home: "/Users/u" })
    ).toBe("/Users/u/.codex/skills")
  })

  it("honors XDG_CONFIG_HOME for ~/.config paths", () => {
    expect(
      resolveNativeConfigPath("~/.config/opencode/skills", {
        env: { XDG_CONFIG_HOME: "/xdg" },
        home: "/Users/u"
      })
    ).toBe("/xdg/opencode/skills")
  })

  it("ignores empty XDG_CONFIG_HOME", () => {
    expect(
      resolveNativeConfigPath("~/.config/opencode/skills", {
        env: { XDG_CONFIG_HOME: "" },
        home: "/Users/u"
      })
    ).toBe("/Users/u/.config/opencode/skills")
  })

  it("passes through absolute paths", () => {
    expect(resolveNativeConfigPath("/etc/skills", { home: "/Users/u" })).toBe("/etc/skills")
  })
})
