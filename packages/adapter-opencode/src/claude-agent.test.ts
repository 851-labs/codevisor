import { execFile } from "node:child_process"
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { expect, it, onTestFinished } from "vitest"

import { claudeAgentEnv, claudeAgentLauncher, type ClaudeAgentLaunch } from "./claude-agent.js"

const exec = promisify(execFile)

const printedEnv = [
  "#!/bin/sh",
  'echo "args=$*"',
  "env | grep -E '^(CLAUDE|ANTHROPIC|CODEVISOR)' | sort",
  ""
].join("\n")

const shell = {
  PATH: "/usr/bin:/bin",
  ANTHROPIC_API_KEY: "shell-key",
  ANTHROPIC_AUTH_TOKEN: "shell-token"
}

const runLauncher = async (launch: Omit<ClaudeAgentLaunch, "claudePath">) => {
  const directory = await mkdtemp(join(tmpdir(), "claude-agent-launcher-"))
  onTestFinished(() => rm(directory, { recursive: true, force: true }))
  const launcher = join(directory, "launcher")
  const claudePath = join(directory, "claude")
  await writeFile(launcher, claudeAgentLauncher)
  await writeFile(claudePath, printedEnv)
  await Promise.all([chmod(launcher, 0o700), chmod(claudePath, 0o700)])
  const env = { ...shell, ...claudeAgentEnv(launcher, { claudePath, env: launch.env }) }
  const { stdout } = await exec(launcher, ["--print", "two words"], { env })
  return stdout.trim().split("\n")
}

it("runs claude with only the chosen account's credentials", async () => {
  expect(
    await runLauncher({
      env: {
        CLAUDE_CONFIG_DIR: "/profiles/alice",
        CLAUDE_CODE_OAUTH_TOKEN: "alice-token",
        ANTHROPIC_BASE_URL: "http://127.0.0.1:1/harness/claude",
        OTHER: "ignored"
      }
    })
  ).toEqual([
    "args=--print two words",
    "ANTHROPIC_BASE_URL=http://127.0.0.1:1/harness/claude",
    "CLAUDE_CODE_OAUTH_TOKEN=alice-token",
    "CLAUDE_CONFIG_DIR=/profiles/alice"
  ])
})

it("leaves the shell's Claude login alone for the machine's default account", async () => {
  expect(await runLauncher({ env: {} })).toEqual([
    "args=--print two words",
    "ANTHROPIC_API_KEY=shell-key",
    "ANTHROPIC_AUTH_TOKEN=shell-token"
  ])
})

it("points OpenCode at the launcher without exposing Claude's own variables to it", () => {
  expect(
    claudeAgentEnv("/run/claude", {
      claudePath: "/bin/claude",
      env: { CLAUDE_CONFIG_DIR: "/profiles/bob", ANTHROPIC_API_KEY: "bob-key" }
    })
  ).toEqual({
    OPENCODE_CLAUDE_PATH: "/run/claude",
    CODEVISOR_CLAUDE_AGENT_PATH: "/bin/claude",
    CODEVISOR_CLAUDE_AGENT_CLAUDE_CONFIG_DIR: "/profiles/bob",
    CODEVISOR_CLAUDE_AGENT_ANTHROPIC_API_KEY: "bob-key"
  })
})
