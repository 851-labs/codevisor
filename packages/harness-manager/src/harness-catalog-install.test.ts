import { harnessCatalog, type HarnessDefinition } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it } from "vitest"

import { installCommand, upgradeCommand } from "./harness-lifecycle-support.js"
import {
  agentsStub,
  cleanupLifecycleTests,
  fakeSpawner,
  fakeTerminal,
  harness,
  jsonResponse,
  makeBinDir,
  makeDb,
  waitForLifecycleSettle
} from "./harness-lifecycle-test-support.js"
import { makeHarnessLifecycleManager } from "./harness-lifecycle.js"

afterEach(cleanupLifecycleTests)

const definition = (id: string): HarnessDefinition => {
  const entry = harnessCatalog.find((candidate) => candidate.id === id)
  if (entry === undefined) throw new Error(`Missing catalog entry: ${id}`)
  return entry
}

describe("catalog installation routes", () => {
  it("offers Codex's script without requiring npm or Homebrew", async () => {
    const lifecycle = makeHarnessLifecycleManager({
      agents: agentsStub([definition("codex")], []),
      db: await makeDb(),
      resolveEnv: async () => ({ PATH: makeBinDir(["curl"]) })
    })
    expect(await lifecycle.installMethods("codex")).toContainEqual({
      id: "curl",
      kind: "curl",
      label: "Installer script",
      command: "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
      available: true,
      recommended: true
    })
  })

  it.each([false, true])("checks uv availability on PATH (installed: %s)", async (available) => {
    const env = { PATH: makeBinDir(available ? ["uv"] : []) }
    const lifecycle = makeHarnessLifecycleManager({
      agents: agentsStub([definition("openhands")], []),
      db: await makeDb(),
      resolveEnv: async () => env
    })
    expect((await lifecycle.installMethods("openhands")).find((m) => m.id === "uv")).toMatchObject({
      available,
      recommended: available,
      label: "uv",
      command: "uv tool install openhands --python 3.12"
    })
  })

  it("keeps macOS casks unavailable on a Linux host with Homebrew", async () => {
    const lifecycle = makeHarnessLifecycleManager({
      agents: agentsStub([definition("codex"), definition("github-copilot-cli")], []),
      db: await makeDb(),
      platform: "linux",
      resolveEnv: async () => ({ PATH: makeBinDir(["brew", "curl"]) })
    })
    const codex = await lifecycle.installMethods("codex")
    expect(codex.find((m) => m.id === "brew")).toMatchObject({
      available: false,
      recommended: false
    })
    expect(codex.find((m) => m.id === "curl")).toMatchObject({ available: true, recommended: true })
    expect(
      (await lifecycle.installMethods("github-copilot-cli")).find((m) => m.id === "brew")
    ).toMatchObject({ available: true, recommended: true })
    await expect(lifecycle.beginInstall("codex", "brew")).rejects.toThrow(
      "No runnable install method"
    )
  })

  it.each([
    [
      "mistral-vibe",
      "/Users/dev/.local/share/uv/tools/mistral-vibe/bin/vibe-acp",
      "uv tool upgrade mistral-vibe"
    ],
    ["factory-droid", "/opt/homebrew/Caskroom/droid/1.0.0/droid", "brew upgrade --cask droid"],
    [
      "github-copilot-cli",
      "/opt/homebrew/Cellar/copilot-cli/1.0.0/bin/copilot",
      "brew upgrade copilot-cli"
    ],
    ["qwen-code", "/opt/homebrew/Cellar/qwen-code/1.0.0/bin/qwen", "brew upgrade qwen-code"]
  ])("updates %s through its installed owner", async (id, path, command) => {
    const { spawnShell, spawns, processes } = fakeSpawner()
    const lifecycle = makeHarnessLifecycleManager({
      agents: agentsStub([definition(id)], [harness(id, path!, "1.0.0")]),
      db: await makeDb(),
      home: "/Users/dev",
      realpath: (p) => p,
      resolveEnv: async () => ({ PATH: makeBinDir(["brew", "uv"]) }),
      fetchImpl: async () => jsonResponse({}, 404),
      spawnShell,
      terminal: fakeTerminal().terminal
    })
    await lifecycle.beginUpdate(id!)
    expect(spawns[0]?.command).toBe(command)
    const settled = waitForLifecycleSettle(lifecycle)
    processes[0]?.emitExit(0)
    await settled
  })

  it("installs all adapter dependencies and preserves npm's ignore-scripts option on updates", () => {
    const amp = definition("amp").installMethods![0]!
    expect(installCommand(amp)).toBe("npm install -g amp-acp @ampcode/cli")
    expect(upgradeCommand(amp)).toBe("npm install -g amp-acp@latest @ampcode/cli@latest")
    const pi = definition("pi").installMethods!.find((m) => m.kind === "npm")!
    expect(installCommand(pi)).toBe(
      "npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
    )
    expect(upgradeCommand(pi)).toBe(
      "npm install -g --ignore-scripts @earendil-works/pi-coding-agent@latest"
    )
  })
})
