import { mkdtemp, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { makeAcpAgentRuntime, makeConnector, run } from "./test-support.js"

const sink = (): void => undefined

describe("ACP harness launch", () => {
  it("launches harnesses with their native subagents turned off", async () => {
    const launchFilesDirectory = await mkdtemp(join(tmpdir(), "codevisor-launch-files-"))
    try {
      const connector = makeConnector()
      const runtime = makeAcpAgentRuntime({
        connector,
        env: { PATH: "/bin" },
        executableExists: () => true,
        launchFilesDirectory,
        locateExecutable: (name) => `/bin/${name}`
      })
      const launch = async (harnessId: string) => {
        await run(runtime.createAgentSession(harnessId, "/tmp/project", sink))
        return connector.requests.find((request) => request.harnessId === harnessId)
      }

      const gemini = await launch("gemini")
      const policy = join(launchFilesDirectory, "gemini", "gemini-subagents.toml")
      expect(gemini?.args).toEqual(["--acp", "--admin-policy", policy])
      expect(await readFile(policy, "utf8")).toMatch(/toolName = "invoke_agent"\ndecision = "deny"/)
      expect(JSON.parse((await launch("kilo"))?.env.KILO_PERMISSION ?? "")).toEqual({
        task: "deny"
      })
      expect((await launch("qwen-code"))?.args).toEqual(
        expect.arrayContaining(["--exclude-tools", "agent,list_agents,send_message"])
      )
      expect((await launch("github-copilot-cli"))?.args).toContain(
        "--excluded-tools=task,list_agents,read_agent,write_agent"
      )
      expect((await launch("auggie"))?.args).toEqual(
        expect.arrayContaining(["--remove-tool", "sub-agent", "--remove-tool", "sub-agent-explore"])
      )
    } finally {
      await rm(launchFilesDirectory, { force: true, recursive: true })
    }
  })
})
