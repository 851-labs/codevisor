import { describe, expect, it } from "vitest"
import { displayPluginCommand, pluginRunCommand, pluginSetupCommands } from "./plugin-command.js"
import { exampleManifest } from "./test-support.js"

describe("plugin commands", () => {
  it("adapts protocol v1 shell commands", () => {
    const manifest = {
      ...exampleManifest,
      install: { command: "npm install && npm run build" }
    }
    expect(pluginRunCommand(manifest)).toEqual({ command: "run-me", kind: "shell" })
    expect(pluginSetupCommands(manifest, "darwin")).toEqual([
      { command: "npm install && npm run build", kind: "shell" }
    ])
  })

  it("filters protocol v2 setup steps by platform", () => {
    const manifest = {
      ...exampleManifest,
      protocolVersion: 2 as const,
      run: { argv: ["node", "server.js"] },
      setup: [
        { argv: ["npm", "ci"] },
        { argv: ["make", "mac"], platforms: ["darwin"] },
        { argv: ["make", "linux"], platforms: ["linux"] }
      ]
    }
    expect(pluginRunCommand(manifest)).toEqual({ argv: ["node", "server.js"], kind: "argv" })
    expect(pluginSetupCommands(manifest, "darwin")).toEqual([
      { argv: ["npm", "ci"], kind: "argv" },
      { argv: ["make", "mac"], kind: "argv" }
    ])
  })

  it("treats an omitted protocol v2 setup list as empty", () => {
    const manifest = {
      ...exampleManifest,
      protocolVersion: 2 as const,
      run: { argv: ["node", "server.js"] }
    }
    expect(pluginSetupCommands(manifest, "darwin")).toEqual([])
  })

  it("renders argv without hiding argument boundaries", () => {
    expect(
      displayPluginCommand({ argv: ["node", "file with spaces.js", "", "--port=4"], kind: "argv" })
    ).toBe('node "file with spaces.js" "" --port=4')
  })
})
