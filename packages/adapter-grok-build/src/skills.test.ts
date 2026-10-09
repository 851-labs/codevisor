import { describe, expect, it } from "vitest"

import { withGrokSkillsDisabled } from "./skills.js"

const toolGateway = { bearerToken: "t", name: "codevisor", url: "http://127.0.0.1:1/mcp" }
const superseded = ["built-in-browser", "chrome-browser", "computer-use"]
const overlay = (env: NodeJS.ProcessEnv) => JSON.parse(env.GROK_CONFIG!)

describe("Grok skills", () => {
  it("disables Claude's browser and desktop skills when Codevisor's tools are attached", () => {
    const env = withGrokSkillsDisabled({ HOME: "/home/u" }, { toolGateway }, () => undefined)
    expect(overlay(env)).toEqual({ skills: { disabled: superseded } })
    expect(withGrokSkillsDisabled({ HOME: "/home/u" }, {}, () => undefined)).toEqual({
      HOME: "/home/u"
    })
  })

  it("keeps the skills the user's configs already disable", () => {
    const files: Record<string, string> = {
      "/grok/config.toml": '[skills]\ndisabled = ["noisy"]\npaths = ["~/x"]\n',
      "/grok/managed_config.toml": '[skills]\ndisabled = ["blocked", "computer-use"]\n'
    }
    const env = withGrokSkillsDisabled(
      {
        GROK_CONFIG: JSON.stringify({
          model: "grok-5",
          skills: { disabled: ["inline"], ignore: ["/i"] }
        }),
        GROK_HOME: "/grok"
      },
      { toolGateway },
      (path) => files[path]
    )
    expect(overlay(env)).toEqual({
      model: "grok-5",
      skills: {
        disabled: [
          "blocked",
          "computer-use",
          "noisy",
          "inline",
          "built-in-browser",
          "chrome-browser"
        ],
        ignore: ["/i"]
      }
    })
  })

  it("ignores configs Grok couldn't read either", () => {
    const env = withGrokSkillsDisabled(
      { GROK_CONFIG: "{not json", GROK_HOME: "/grok" },
      { toolGateway },
      () => "not = [toml"
    )
    expect(overlay(env)).toEqual({ skills: { disabled: superseded } })
  })
})
