import { appendFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import { nodeSubagentTranscripts } from "./subagent-transcripts.js"

const configDirs: Array<string> = []

afterEach(() => {
  for (const dir of configDirs.splice(0)) rmSync(dir, { force: true, recursive: true })
})

// A config directory holding one subagent transcript in an encoded project dir.
const configWithTranscript = (content: string) => {
  const configDir = mkdtempSync(join(tmpdir(), "codevisor-claude-config-"))
  configDirs.push(configDir)
  const subagents = join(configDir, "projects", "-Users-me-repo", "session-1", "subagents")
  mkdirSync(subagents, { recursive: true })
  const path = join(subagents, "agent-task-1.jsonl")
  writeFileSync(path, content)
  return { configDir, path }
}

describe("subagent transcripts", () => {
  it("finds a subagent's transcript in whichever project holds its session", () => {
    const { configDir, path } = configWithTranscript("")
    const transcripts = nodeSubagentTranscripts(configDir)

    expect(transcripts.locate("session-1", "task-1")).toBe(path)
    expect(transcripts.locate("session-1", "task-2")).toBeUndefined()
    expect(nodeSubagentTranscripts(join(configDir, "missing")).locate("session-1", "task-1")).toBe(
      undefined
    )
  })

  it("returns only whole lines, leaving a line still being written for later", () => {
    const { configDir, path } = configWithTranscript('{"a":"é"}\n{"b":')
    const transcripts = nodeSubagentTranscripts(configDir)

    const first = transcripts.readLines(path, 0)
    expect(first.text).toBe('{"a":"é"}\n')
    expect(transcripts.readLines(path, first.offset)).toEqual({ offset: first.offset, text: "" })

    appendFileSync(path, "2}\n")
    expect(transcripts.readLines(path, first.offset).text).toBe('{"b":2}\n')
  })
})
