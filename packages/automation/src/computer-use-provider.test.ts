import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { describe, expect, it } from "vitest"
import { computerUseTools, linuxComputerUseHelperPath } from "./computer-use-provider.js"

describe("Computer Use tool contract", () => {
  it("finds the Linux helper in a packaged runtime launched from another directory", () => {
    const root = mkdtempSync(join(tmpdir(), "codevisor-packaged-computer-use-"))
    try {
      const runtime = join(root, "linux-x64")
      const helper = join(runtime, "packages", "automation", "resources", "computer-use-linux.py")
      mkdirSync(dirname(helper), { recursive: true })
      writeFileSync(helper, "# helper")

      expect(
        linuxComputerUseHelperPath({
          moduleDirectory: join(runtime, "packages", "automation", "dist"),
          workingDirectory: "/"
        })
      ).toBe(helper)
    } finally {
      rmSync(root, { force: true, recursive: true })
    }
  })

  it("detects AT-SPI text support through the introspected text interface", () => {
    const source = readFileSync(
      join(dirname(fileURLToPath(import.meta.url)), "..", "resources", "computer-use-linux.py"),
      "utf8"
    )
    expect(source).not.toContain("node.is_text")
    expect(source).toContain("interface = safe(node.get_text_iface)")
    expect(source).toContain("if interface is not None:")
  })

  it("exposes explicit snapshots, observations, waits and the persistent REPL", () => {
    const names = computerUseTools.map((tool) => tool.name)
    expect(names).toContain("js")
    expect(names).toContain("reset")
    expect(names).toContain("wait_for")
    expect(names).toContain("paste_text")
    for (const name of ["click", "drag", "set_value", "select_text", "perform_secondary_action"]) {
      const schema = computerUseTools.find((tool) => tool.name === name)!.inputSchema
      expect(schema.properties).toHaveProperty("snapshot_id")
      expect(schema.properties).toHaveProperty("window_id")
      expect(schema.properties).toHaveProperty("delivery_mode")
    }
    const state = computerUseTools.find((tool) => tool.name === "get_app_state")!
    expect(state.inputSchema.properties).toHaveProperty("screenshot")
    expect(state.inputSchema.properties).toHaveProperty("view")
    expect(state.description).toContain("Actions never take hidden snapshots")
  })

  it("advertises installed app discovery and transparent launching", () => {
    const list = computerUseTools.find((candidate) => candidate.name === "list_apps")
    const state = computerUseTools.find((candidate) => candidate.name === "get_app_state")

    expect(list?.description).toContain("installed desktop applications")
    expect(list?.description).toContain("whether each app is running")
    expect(state?.description).toContain("Launch the app if needed")
  })

  it("exposes exact semantic text selection", () => {
    const select = computerUseTools.find((candidate) => candidate.name === "select_text")
    const schema = select?.inputSchema as unknown as {
      additionalProperties: boolean
      properties: Record<string, { enum?: string[] }>
      required: string[]
    }
    expect(schema.properties).not.toHaveProperty("all")
    expect(schema.properties).toHaveProperty("text")
    expect(schema.properties).toHaveProperty("prefix")
    expect(schema.properties).toHaveProperty("suffix")
    expect(schema.properties.selection_type?.enum).toEqual([
      "text",
      "cursor_before",
      "cursor_after"
    ])
    expect(schema.required).toEqual(["app", "element_index", "text"])
    expect(schema.additionalProperties).toBe(false)
  })

  it("rejects undeclared action arguments", () => {
    for (const candidate of computerUseTools) {
      const schema = candidate.inputSchema as unknown as {
        properties?: Record<string, unknown>
        additionalProperties?: boolean
      }
      expect(schema.properties ?? {}).not.toHaveProperty("snapshotId")
      expect(schema.properties ?? {}).not.toHaveProperty("elementId")
      expect(schema.properties ?? {}).not.toHaveProperty("deliveryMode")
      expect(schema.additionalProperties).toBe(false)
    }
  })

  it("accepts the disableDiff option and rejects undeclared arguments", () => {
    const state = computerUseTools.find((candidate) => candidate.name === "get_app_state")
    const schema = state?.inputSchema as unknown as {
      additionalProperties: boolean
      properties: Record<string, unknown>
    }
    expect(schema.properties).toHaveProperty("disableDiff")
    expect(schema.additionalProperties).toBe(false)
  })
})
