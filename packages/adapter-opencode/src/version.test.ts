import { expect, it } from "vitest"

import { makeOpenCodeVersionProbe, parseOpenCodeMajorVersion } from "./version.js"

it("reads both OpenCode version formats", () => {
  expect(parseOpenCodeMajorVersion("opencode v2.0.24\n")).toBe(2)
  expect(parseOpenCodeMajorVersion("1.18.34\n")).toBe(1)
  expect(parseOpenCodeMajorVersion("opencode (dev)\n")).toBeUndefined()
})

it("asks a binary for its version once, and again after it changes", async () => {
  let modified = 1
  let output = "1.18.34\n"
  const runs: string[] = []
  const probe = makeOpenCodeVersionProbe({
    run: async (command) => {
      runs.push(command)
      if (command === "/missing") throw new Error("ENOENT")
      return output
    },
    modified: async () => modified
  })
  expect([await probe("/bin/opencode"), await probe("/bin/opencode")]).toEqual([1, 1])
  expect(runs).toEqual(["/bin/opencode"])
  modified = 2
  output = "opencode v2.0.24\n"
  expect(await probe("/bin/opencode")).toBe(2)
  expect(await probe("/missing")).toBeUndefined()
  expect(runs).toEqual(["/bin/opencode", "/bin/opencode", "/missing"])
})
