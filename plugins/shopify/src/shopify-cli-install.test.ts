import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { makeCliLocator, pinnedCliVersion } from "./shopify-cli-install.js"
import { fakeShopifyCli } from "./shopify-test-support.js"

const toolsDir = "/data/tools/shopify-cli"
const managedEntry = join(toolsDir, "node_modules", "@shopify", "cli", "bin", "run.js")
const nodePath = "/codevisor/bin/node"

const locator = (files: ReadonlyArray<string>, fake = fakeShopifyCli()) => {
  const present = new Set(files)
  const has = (path: string) => present.has(path)
  const locate = makeCliLocator({
    env: { PATH: "/usr/local/bin:/opt/homebrew/bin" },
    toolsDir,
    nodePath,
    run: async (command, args, options) => {
      const result = await fake.run(command, args, options)
      if (result.code === 0) present.add(managedEntry)
      return result
    },
    isExecutable: has,
    exists: has
  })
  return { locate, fake }
}

describe("finding the Shopify CLI", () => {
  it("uses a shopify already on PATH, then Codevisor's own copy", async () => {
    const onPath = locator(["/opt/homebrew/bin/shopify", managedEntry])
    const managed = locator([managedEntry])

    expect(await onPath.locate()).toEqual({ command: "/opt/homebrew/bin/shopify", args: [] })
    expect(await managed.locate()).toEqual({ command: nodePath, args: [managedEntry] })
  })

  it("installs the pinned CLI with npm once, even when two calls need it", async () => {
    const { locate, fake } = locator(["/usr/local/bin/npm"])
    fake.respond({ code: 0 })

    const located = await Promise.all([locate(), locate()])

    expect(located).toEqual([
      { command: nodePath, args: [managedEntry] },
      { command: nodePath, args: [managedEntry] }
    ])
    expect(fake.calls).toEqual([
      {
        command: "/usr/local/bin/npm",
        args: [
          "install",
          "--prefix",
          toolsDir,
          "--no-audit",
          "--no-fund",
          "--loglevel=error",
          `@shopify/cli@${pinnedCliVersion}`
        ]
      }
    ])
  })

  it("explains what's missing when it can't install", async () => {
    const withoutNpm = locator([])
    const failing = locator(["/usr/local/bin/npm"])
    failing.fake.respond({ code: 1, stderr: "npm ERR! network unreachable\n" })

    await expect(withoutNpm.locate()).rejects.toThrow("Install Node.js from https://nodejs.org")
    await expect(failing.locate()).rejects.toThrow(
      "Couldn't install the Shopify CLI: npm ERR! network unreachable"
    )
  })
})
