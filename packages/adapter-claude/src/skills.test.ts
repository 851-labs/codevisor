import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"

import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  run,
  systemMessage
} from "./test-support.js"

const skillUpdates = (events: ReadonlyArray<RuntimeEvent>) =>
  events
    .map((event) => event.payload as Record<string, unknown>)
    .filter((payload) => payload.sessionUpdate === "available_skills_update")
    .map((payload) =>
      (payload.skills as ReadonlyArray<{ readonly name: string }>).map((skill) => skill.name)
    )

describe("Claude skills", () => {
  it("lists only skills, with where each one comes from", async () => {
    const fake = new FakeQuery()
    fake.commands = [
      { description: "Build the app. (project)", name: "build-app" },
      { description: "Write a chart. (user)", name: "dataviz" },
      { builtin: true, description: "Review the changed code.", name: "simplify" },
      { description: "Make a deck. (claude.ai sync)", name: "anthropic-skills:pptx" },
      { builtin: true, description: "Free up context", name: "compact" },
      { builtin: true, description: "Run a workflow", name: "__remote-workflow" },
      { description: "Summarize a PR", name: "github:summarize (MCP)" }
    ]
    const created = await run(makeProvider(fake).createSession(definition, "/tmp", async () => {}))

    expect(created.metadata.skills).toEqual({
      invocationPrefix: "/",
      skills: [
        {
          description: "Build the app.",
          invocation: "/build-app",
          name: "build-app",
          source: "project"
        },
        { description: "Write a chart.", invocation: "/dataviz", name: "dataviz", source: "user" },
        {
          description: "Review the changed code.",
          invocation: "/simplify",
          name: "simplify",
          source: "builtin"
        },
        {
          description: "Make a deck. (claude.ai sync)",
          invocation: "/anthropic-skills:pptx",
          name: "anthropic-skills:pptx",
          source: "plugin"
        }
      ]
    })
  })

  it("learns built-in commands from init for this and later sessions", async () => {
    const fake = new FakeQuery()
    const commands = [
      { builtin: true, description: "Review the changed code.", name: "simplify" },
      { builtin: true, description: "Brand new command", name: "teleport" }
    ]
    fake.commands = commands
    const provider = makeProvider(fake)
    const events: RuntimeEvent[] = []
    await run(provider.createSession(definition, "/tmp", async (event) => void events.push(event)))
    expect(skillUpdates(events)).toEqual([["simplify", "teleport"]])

    // `init` arrives with the first turn and names the skills exactly.
    fake.push({
      ...(initMessage() as object),
      skills: ["simplify"],
      slash_commands: ["simplify", "teleport"]
    } as never)
    await fake.drain()
    expect(skillUpdates(events)).toEqual([["simplify", "teleport"], ["simplify"]])

    const next = new FakeQuery()
    next.commands = commands
    fake.successors.push(next)
    const later = await run(provider.createSession(definition, "/tmp", async () => {}))
    expect(later.metadata.skills?.skills.map((skill) => skill.name)).toEqual(["simplify"])
  })

  it("replaces the list when the CLI reports a mid-session change", async () => {
    const fake = new FakeQuery()
    fake.commands = [{ description: "Build the app. (project)", name: "build-app" }]
    const events: RuntimeEvent[] = []
    await run(
      makeProvider(fake).createSession(definition, "/tmp", async (event) => void events.push(event))
    )

    fake.push(
      systemMessage("commands_changed", {
        commands: [
          { description: "Build the app. (project)", name: "build-app" },
          { description: "Ship it. (project)", name: "ship" }
        ]
      })
    )
    // An unchanged list is not published again.
    fake.push(
      systemMessage("commands_changed", {
        commands: [
          { description: "Build the app. (project)", name: "build-app" },
          { description: "Ship it. (project)", name: "ship" }
        ]
      })
    )
    await fake.drain()

    expect(skillUpdates(events)).toEqual([["build-app"], ["build-app", "ship"]])
  })
})
