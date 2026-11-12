import { toolText } from "@codevisor/plugin-kit/test-support"
import { describe, expect, it } from "vitest"

import {
  callSlackTool,
  connectSlack,
  dana,
  eng,
  fileDownloadUrl,
  sam,
  slackAccountMeta
} from "./slack-test-support.js"

describe("threads, people and files", () => {
  it("reads a thread with its files and reactions", async () => {
    const connected = await connectSlack()
    connected.slack.on("conversations.replies", () => ({
      messages: [
        {
          ts: "1731350000.000100",
          user: sam.id,
          text: "Plan",
          thread_ts: "1731350000.000100",
          reply_count: 1
        },
        {
          ts: "1731350001.000100",
          user: dana.id,
          text: "Attached",
          thread_ts: "1731350000.000100",
          files: [{ id: "F0PLAN00001", name: "plan.pdf", title: "Plan" }],
          reactions: [{ name: "eyes", count: 2 }]
        }
      ]
    }))

    const result = await callSlackTool(connected, "read_thread", {
      channel: eng.id,
      ts: "1731350000.000100"
    })

    expect(connected.slack.called("conversations.replies")).toEqual([
      { channel: eng.id, ts: "1731350000.000100", limit: "50" }
    ])
    expect(result.structuredContent).toEqual({
      channel: eng.id,
      messages: [
        { ts: "1731350000.000100", author: sam.id, text: "Plan", replies: 1 },
        {
          ts: "1731350001.000100",
          threadTs: "1731350000.000100",
          author: dana.id,
          text: "Attached",
          files: [{ id: "F0PLAN00001", name: "Plan" }],
          reactions: [{ emoji: "eyes", count: 2 }]
        }
      ],
      people: { [sam.id]: "Sam", [dana.id]: "Dana" }
    })
  })

  it("gets the user's own profile and someone else's by handle", async () => {
    const connected = await connectSlack()

    const me = await callSlackTool(connected, "get_user", { user: "me" })
    const other = await callSlackTool(connected, "get_user", { user: "@sam" })
    const nobody = await callSlackTool(connected, "get_user", { user: "@ghost" })

    expect(me.structuredContent).toEqual({ id: dana.id, name: "Dana", handle: "dana" })
    expect(other.structuredContent).toEqual({
      id: sam.id,
      name: "Sam",
      handle: "sam",
      title: "SRE",
      email: "sam@acme.com",
      timeZone: "America/New_York"
    })
    expect(toolText(nobody)).toBe(
      "Nobody in this workspace goes by @ghost. Use find_users to look them up."
    )
  })

  it("names a channel's members", async () => {
    const connected = await connectSlack()
    connected.slack.on("conversations.members", () => ({
      members: [dana.id, sam.id, "U0GONE00001"],
      response_metadata: { next_cursor: "more" }
    }))

    const result = await callSlackTool(connected, "list_channel_members", { channel: "#eng" })

    expect(result.structuredContent).toEqual({
      channel: eng.id,
      members: [
        { id: dana.id, name: "Dana" },
        { id: sam.id, name: "Sam" },
        { id: "U0GONE00001", name: "U0GONE00001" }
      ],
      nextCursor: "more"
    })
  })

  it("searches files", async () => {
    const connected = await connectSlack()
    connected.slack.on("search.files", () => ({
      files: {
        matches: [
          {
            id: "F0PLAN00001",
            name: "plan.pdf",
            filetype: "pdf",
            user: sam.id,
            permalink: "https://acme.slack.com/files/x"
          }
        ]
      }
    }))

    const result = await callSlackTool(connected, "search_files", { query: "plan", count: 5 })

    expect(connected.slack.called("search.files")).toEqual([
      { query: "plan", count: "5", page: "1" }
    ])
    expect(result.structuredContent).toEqual({
      files: [
        {
          id: "F0PLAN00001",
          name: "plan.pdf",
          type: "pdf",
          sharedBy: sam.id,
          link: "https://acme.slack.com/files/x"
        }
      ]
    })
  })

  it("filters listed channels by name", async () => {
    const connected = await connectSlack()

    const result = await callSlackTool(connected, "list_channels", { query: "#INC" })

    expect(result.structuredContent).toEqual({
      channels: [{ id: "C0INC000001", name: "incidents", type: "public", topic: "Pager" }]
    })
  })
})

describe("downloads and reactions", () => {
  it("keeps binary files on disk without inlining them, and explains files Slack won't hand over", async () => {
    const connected = await connectSlack()
    const files = new Map([
      [
        "F0PDF000001",
        {
          id: "F0PDF000001",
          name: "plan.pdf",
          mimetype: "application/pdf",
          url_private: fileDownloadUrl
        }
      ],
      ["F0POST00001", { id: "F0POST00001", title: "Post" }]
    ])
    connected.slack.on("files.info", (params) => ({ file: files.get(params.file ?? "") }))

    const pdf = await callSlackTool(connected, "download_file", { file: "F0PDF000001" })
    const post = await callSlackTool(connected, "download_file", { file: "F0POST00001" })

    expect(pdf.structuredContent).not.toHaveProperty("text")
    expect(pdf.structuredContent).toMatchObject({
      path: "/tmp/codevisor-slack/F0PDF000001/plan.pdf"
    })
    expect(toolText(post)).toBe("Slack doesn't offer a download for that file.")
  })

  it("removes a reaction", async () => {
    const connected = await connectSlack()
    connected.slack.on("reactions.remove", () => ({}))

    const result = await callSlackTool(connected, "remove_reaction", {
      channel: eng.id,
      ts: "1731350001.000000",
      emoji: "eyes"
    })

    expect(connected.slack.called("reactions.remove")).toEqual([
      { channel: eng.id, timestamp: "1731350001.000000", name: "eyes" }
    ])
    expect(result.structuredContent).toEqual({ ok: true, emoji: "eyes" })
  })

  it("rejects times it can't read", async () => {
    const connected = await connectSlack()

    const result = await callSlackTool(connected, "read_channel", {
      channel: eng.id,
      latest: "soon"
    })

    expect(toolText(result)).toContain("soon isn't a ts or ISO time.")
  })
})

describe("tool calls without a usable account", () => {
  it("asks for an account when none is connected", async () => {
    const connected = await connectSlack()

    const result = await connected.client.callTool({
      name: "read_channel",
      arguments: { channel: eng.id }
    })

    expect(toolText(result)).toBe(
      "A connected Slack account is required. Set one up from Settings › Plugins › Slack."
    )
  })

  it("rejects unknown tools and invalid arguments", async () => {
    const connected = await connectSlack()

    const unknown = await callSlackTool(connected, "delete_workspace", {})
    const invalid = await connected.client.callTool({
      name: "read_thread",
      arguments: { channel: eng.id, ts: "yesterday" },
      _meta: slackAccountMeta()
    })

    expect(toolText(unknown)).toBe("Unknown tool: delete_workspace")
    expect(toolText(invalid)).toContain("Use a Slack message ts")
  })
})
