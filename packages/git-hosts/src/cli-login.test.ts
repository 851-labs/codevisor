import { describe, expect, it } from "vitest"

import { startDeviceLogin } from "./cli-login.js"
import { runCli } from "./cli-process.js"
import { emptyEnv, testTempDir } from "./test-support.js"

describe("CLI processes", () => {
  it("reports a CLI that vanished or can't be run", async () => {
    const env = emptyEnv()
    const vanished = startDeviceLogin(
      { command: "gh", path: "/nonexistent/codevisor/gh", args: [], env },
      () => undefined
    )
    const directory = startDeviceLogin(
      { command: "gh", path: testTempDir("codevisor-not-a-cli-"), args: [], env },
      () => undefined
    )

    expect(await vanished.finished).toEqual({
      signedIn: false,
      message: "gh isn't installed on this machine"
    })
    expect(await directory.finished).toMatchObject({ signedIn: false, message: /EACCES/ })
  })

  it("answers a command that couldn't start with its error", async () => {
    const result = await runCli("/nonexistent/codevisor/gh", ["--version"], emptyEnv(), {
      timeoutMs: 1_000
    })

    expect(result).toMatchObject({ exitCode: null, output: expect.stringMatching(/ENOENT/) })
  })
})
