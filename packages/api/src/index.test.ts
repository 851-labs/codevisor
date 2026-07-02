import { describe, expect, it } from "vitest"
import {
  CreateProjectRequest,
  CreateSessionRequest,
  CreateWorktreeRequest,
  EventEnvelope,
  Project,
  ServerCapabilities,
  SessionDetail,
  TerminalClientFrame,
  Worktree,
  decode,
  encode,
  endpoints,
  isoTimestamp,
  makeOpenApiDocument
} from "./index.js"

describe("@herdman/api", () => {
  it("decodes and encodes project payloads", () => {
    const project = decode(Project)({
      id: "project-1",
      name: "HerdMan",
      isArchived: false,
      symbolName: "folder",
      origin: "herdman",
      createdAt: "2026-06-30T00:00:00.000Z",
      locations: [
        {
          id: "location-1",
          projectId: "project-1",
          serverId: "local",
          folderPath: "/Users/me/src/HerdMan",
          createdAt: "2026-06-30T00:00:00.000Z",
          isGitRepository: true
        }
      ]
    })

    expect(encode(Project)(project)).toEqual({
      id: "project-1",
      name: "HerdMan",
      isArchived: false,
      symbolName: "folder",
      origin: "herdman",
      createdAt: "2026-06-30T00:00:00.000Z",
      locations: [
        {
          id: "location-1",
          projectId: "project-1",
          serverId: "local",
          folderPath: "/Users/me/src/HerdMan",
          createdAt: "2026-06-30T00:00:00.000Z",
          isGitRepository: true
        }
      ]
    })
  })

  it("accepts client-provided creation metadata", () => {
    expect(
      decode(CreateProjectRequest)({
        id: "project-1",
        folderPath: "/Users/me/src/HerdMan",
        name: "HerdMan",
        isArchived: true,
        symbolName: "archivebox",
        origin: "imported",
        createdAt: "2026-06-30T00:00:00.000Z"
      })
    ).toMatchObject({
      id: "project-1",
      isArchived: true,
      origin: "imported",
      symbolName: "archivebox"
    })

    expect(
      decode(CreateSessionRequest)({
        id: "session-1",
        projectId: "project-1",
        harnessId: "codex",
        agentSessionId: "agent-1",
        title: "Synced",
        origin: "herdman",
        isArchived: false,
        worktreeName: "fix-auth",
        createdAt: "2026-06-30T00:00:00.000Z",
        updatedAt: "2026-06-30T00:01:00.000Z"
      })
    ).toMatchObject({
      agentSessionId: "agent-1",
      id: "session-1",
      title: "Synced",
      worktreeName: "fix-auth"
    })
  })

  it("decodes worktrees and worktree creation requests", () => {
    expect(
      decode(Worktree)({
        id: "worktree-1",
        projectId: "project-1",
        serverId: "local",
        name: "fix-auth",
        branch: "herdman/fix-auth",
        path: "/Users/me/herdman/project-1/fix-auth",
        createdAt: "2026-06-30T00:00:00.000Z"
      }).branch
    ).toBe("herdman/fix-auth")

    expect(decode(CreateWorktreeRequest)({})).toEqual({})
    expect(decode(CreateWorktreeRequest)({ name: "fix-auth" })).toEqual({ name: "fix-auth" })
  })

  it("rejects invalid terminal frames", () => {
    expect(() => decode(TerminalClientFrame)({ type: "resize", cols: "80", rows: 24 })).toThrow()
  })

  it("allows opaque event payloads", () => {
    const event = decode(EventEnvelope)({
      id: 1,
      serverId: "local",
      kind: "session.output",
      subjectId: "session-1",
      createdAt: "2026-06-30T00:00:00.000Z",
      payload: { text: "hello" }
    })
    expect(event.payload).toEqual({ text: "hello" })
  })

  it("decodes session details with an event replay cursor", () => {
    const detail = decode(SessionDetail)({
      session: {
        id: "session-1",
        projectId: "project-1",
        serverId: "local",
        harnessId: "codex",
        title: "Synced",
        origin: "herdman",
        isArchived: false,
        createdAt: "2026-06-30T00:00:00.000Z"
      },
      conversation: [
        {
          id: "item-1",
          role: "user",
          messageId: "user-1",
          text: "hello",
          createdAt: "2026-06-30T00:00:01.000Z",
          isGenerating: false
        }
      ],
      promptQueue: [
        {
          id: "queue-1",
          sessionId: "session-1",
          text: "follow up",
          createdAt: "2026-06-30T00:00:02.000Z",
          updatedAt: "2026-06-30T00:00:02.000Z"
        }
      ],
      eventCursor: 7
    })
    expect(detail.eventCursor).toBe(7)
    expect(detail.conversation[0]?.role).toBe("user")
    expect(detail.conversation[0]?.messageId).toBe("user-1")
    expect(detail.promptQueue[0]?.text).toBe("follow up")
  })

  it("decodes harness capabilities with modes and config options", () => {
    const capabilities = decode(ServerCapabilities)({
      harnesses: [
        {
          harness: {
            id: "codex",
            name: "Codex",
            symbolName: "chevron.left.forwardslash.chevron.right",
            source: "registry",
            launchKind: "npx",
            enabled: true,
            readiness: { state: "ready" }
          },
          modes: {
            currentModeId: "default",
            availableModes: [{ id: "default", name: "Default" }]
          },
          configOptions: [
            {
              id: "model",
              name: "Model",
              category: "model",
              currentValue: "gpt-5",
              options: [{ value: "gpt-5", name: "GPT-5" }]
            },
            {
              id: "grouped",
              name: "Grouped",
              currentValue: "a",
              options: [{ group: "main", name: "Main", options: [{ value: "a", name: "A" }] }]
            }
          ]
        }
      ]
    })
    expect(capabilities.harnesses[0]?.configOptions.map((option) => option.id)).toEqual([
      "model",
      "grouped"
    ])
  })

  it("exports the server endpoint inventory as OpenAPI metadata", () => {
    const doc = makeOpenApiDocument("0.1.0")
    expect(doc.info.version).toBe("0.1.0")
    expect(Object.keys(doc.paths).sort()).toEqual([...endpoints].sort())
  })

  it("creates ISO timestamps for server state", () => {
    expect(Date.parse(isoTimestamp())).not.toBeNaN()
  })
})
