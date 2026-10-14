import { describe, expect, it } from "vitest"

import { agySessionSummaries, summariesPath } from "./sessions.js"

describe("agy conversation index", () => {
  it("lists top-level conversations with their workspace, time and title", () => {
    expect(summariesPath("/home/me/.gemini")).toBe(
      "/home/me/.gemini/antigravity-cli/conversation_summaries.db"
    )
    expect(
      agySessionSummaries([
        {
          conversation_id: "c-1",
          title: " Fix the build ",
          workspace_uris: '["file:///Users/me/repo","file:///Users/me/other"]',
          last_modified_time: 1_760_000_000
        },
        {
          conversation_id: "c-2",
          title: "",
          preview: "Explain this",
          workspace_uris: "file:///Users/me/a%20b,file:///Users/me/c",
          last_modified_time: 1_760_000_000_000,
          parent_conversation_id: ""
        },
        {
          conversation_id: "c-3",
          workspace_uris: '"/Users/me/plain"',
          last_modified_time: "2026-10-13T12:00:00Z",
          nesting_depth: 0
        },
        {
          conversation_id: "c-4",
          workspace_uris: "file:///Users/me/repo",
          last_modified_time: "1760000000"
        }
      ])
    ).toEqual([
      {
        sessionId: "c-1",
        cwd: "/Users/me/repo",
        updatedAt: "2025-10-09T08:53:20.000Z",
        title: "Fix the build"
      },
      {
        sessionId: "c-2",
        cwd: "/Users/me/a b",
        updatedAt: "2025-10-09T08:53:20.000Z",
        title: "Explain this"
      },
      { sessionId: "c-3", cwd: "/Users/me/plain", updatedAt: "2026-10-13T12:00:00.000Z" },
      { sessionId: "c-4", cwd: "/Users/me/repo", updatedAt: "2025-10-09T08:53:20.000Z" }
    ])
  })

  it("leaves out subagent conversations and rows it can't place", () => {
    const row = { conversation_id: "c", workspace_uris: "file:///r", last_modified_time: 1 }
    expect(
      agySessionSummaries([
        { ...row, parent_conversation_id: "p" },
        { ...row, nesting_depth: 1 },
        { ...row, conversation_id: undefined },
        { ...row, workspace_uris: undefined },
        { ...row, workspace_uris: '["", "file://remote-host/x", "relative/dir", 7]' },
        { ...row, last_modified_time: "yesterday" },
        { ...row, last_modified_time: null }
      ])
    ).toEqual([])
  })
})
