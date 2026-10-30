import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

import { describe, expect, it } from "vitest"

import { computerUseTools, linuxComputerUseHelperPath } from "./computer-use-provider.js"
import { recordOrEmpty } from "./unknown-values.js"

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
    expect(state.inputSchema.properties).toHaveProperty("disableDiff")
  })

  it("exposes exact semantic text selection", () => {
    const select = computerUseTools.find((candidate) => candidate.name === "select_text")
    if (select === undefined) throw new Error("Missing select_text tool")
    const schema = select.inputSchema
    expect(schema.properties).not.toHaveProperty("all")
    expect(schema.properties).toHaveProperty("text")
    expect(schema.properties).toHaveProperty("prefix")
    expect(schema.properties).toHaveProperty("suffix")
    expect(recordOrEmpty(schema.properties?.selection_type).enum).toEqual([
      "text",
      "cursor_before",
      "cursor_after"
    ])
    expect(schema.required).toEqual(["app", "element_index", "text"])
    expect(schema.additionalProperties).toBe(false)
  })

  it("rejects undeclared action arguments", () => {
    for (const candidate of computerUseTools) {
      const schema = candidate.inputSchema
      expect(schema.properties ?? {}).not.toHaveProperty("snapshotId")
      expect(schema.properties ?? {}).not.toHaveProperty("elementId")
      expect(schema.properties ?? {}).not.toHaveProperty("deliveryMode")
      expect(schema.additionalProperties).toBe(false)
    }
  })
})
