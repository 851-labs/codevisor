import { toolText } from "@codevisor/plugin-kit/test-support"
import { describe, expect, it } from "vitest"

import {
  callSlackTool,
  connectSlack,
  deployBot,
  eng,
  fileDownloadUrl,
  fileText,
  sam,
  samDm,
  uploadUrl
} from "./slack-test-support.js"

const structured = (result: Awaited<ReturnType<typeof callSlackTool>>) => result.structuredContent

describe("reading", () => {
  it("searches newest first and names the people in the matches", async () => {
    const connected = await connectSlack()
    connected.slack.on("search.messages", () => ({
      messages: {
        matches: [
          {
            ts: "1731350000.000100",
            user: sam.id,
            text: "Ship it <@U0DANA00001>",
            channel: { id: eng.id, name: "eng" },
            permalink: "https://acme.slack.com/archives/C0ENG000001/p1731350000000100"
          }
        ],
        pagination: { page: 1, page_count: 3, total_count: 41 }
      }
    }))

    const result = await callSlackTool(connected, "search_messages", { query: "in:#eng ship" })

    expect(connected.slack.called("search.messages")).toEqual([
      { query: "in:#eng ship", count: "20", page: "1", sort: "timestamp", sort_dir: "desc" }
    ])
    expect(structured(result)).toEqual({
      messages: [
        {
          channel: { id: eng.id, name: "eng" },
          ts: "1731350000.000100",
          author: sam.id,
          text: "Ship it <@U0DANA00001>",
          link: "https://acme.slack.com/archives/C0ENG000001/p1731350000000100"
        }
      ],
      people: { [sam.id]: "Sam", U0DANA00001: "Dana" },
      page: 1,
      pages: 3,
      total: 41
    })
  })

  it("names a DM after the other person and marks only bot users as bots", async () => {
    const connected = await connectSlack()
    connected.slack.on("search.messages", () => ({
      messages: {
        matches: [
          {
            ts: "1731350000.000100",
            user: sam.id,
            bot_id: "B0CODEVISOR",
            text: "Posted through an app",
            channel: { id: samDm.id, name: sam.id }
          },
          {
            ts: "1731350001.000100",
            user: deployBot.id,
            bot_id: "B0DEPLOY001",
            text: "Deploy is green",
            channel: { id: eng.id, name: "eng" }
          }
        ]
      }
    }))

    const result = await callSlackTool(connected, "search_messages", { query: "deploy" })

    expect(structured(result)).toEqual({
      messages: [
        {
          channel: { id: samDm.id, name: "Sam" },
          ts: "1731350000.000100",
          author: sam.id,
          text: "Posted through an app"
        },
        {
          channel: { id: eng.id, name: "eng" },
          ts: "1731350001.000100",
          author: deployBot.id,
          bot: true,
          text: "Deploy is green"
        }
      ],
      people: { [sam.id]: "Sam", [deployBot.id]: "Deploy" }
    })
  })

  it("reads a channel by name, oldest message first, and hands back the cursor for older ones", async () => {
    const connected = await connectSlack()
    connected.slack.on("conversations.history", () => ({
      messages: [
        { ts: "1731350002.000000", user: sam.id, text: "second" },
        { ts: "1731350001.000000", user: sam.id, text: "first", reply_count: 2 }
      ],
      response_metadata: { next_cursor: "older" }
    }))

    const result = await callSlackTool(connected, "read_channel", { channel: "#eng", limit: 2 })

    expect(connected.slack.called("conversations.history")).toEqual([
      { channel: eng.id, limit: "2" }
    ])
    expect(structured(result)).toMatchObject({
      channel: eng.id,
      messages: [
        { ts: "1731350001.000000", text: "first", replies: 2 },
        { ts: "1731350002.000000", text: "second" }
      ],
      people: { [sam.id]: "Sam" },
      nextCursor: "older"
    })
  })

  it("turns ISO times into Slack timestamps", async () => {
    const connected = await connectSlack()
    connected.slack.on("conversations.history", () => ({ messages: [] }))

    await callSlackTool(connected, "read_channel", {
      channel: eng.id,
      oldest: "2026-11-11T00:00:00Z"
    })

    expect(connected.slack.called("conversations.history")[0]?.oldest).toBe("1794355200")
  })

  it("says so when the user isn't in a channel by that name", async () => {
    const connected = await connectSlack()

    const result = await callSlackTool(connected, "read_channel", { channel: "#random" })

    expect([result.isError, toolText(result)]).toEqual([
      true,
      "You aren't in a channel named #random. Use list_channels to find it."
    ])
  })

  it("lists DMs under the other person's name", async () => {
    const connected = await connectSlack()
    connected.slack.on("users.conversations", () => ({ channels: [samDm, eng] }))

    const result = await callSlackTool(connected, "list_channels", { types: ["dm", "public"] })

    expect(connected.slack.called("users.conversations")[0]?.types).toBe("im,public_channel")
    expect(structured(result)).toEqual({
      channels: [
        { id: samDm.id, name: "Sam", type: "dm" },
        { id: eng.id, name: "eng", type: "public" }
      ]
    })
  })

  it("finds people by email and by name", async () => {
    const connected = await connectSlack()
    connected.slack.on("users.lookupByEmail", () => ({ user: sam }))

    const byEmail = await callSlackTool(connected, "find_users", { query: "sam@acme.com" })
    const byName = await callSlackTool(connected, "find_users", { query: "lee" })

    const found = { id: sam.id, name: "Sam", handle: "sam", title: "SRE" }
    expect([structured(byEmail), structured(byName)]).toEqual([
      { users: [found] },
      { users: [found] }
    ])
  })

  it("saves a downloaded file and inlines small text", async () => {
    const connected = await connectSlack()
    connected.slack.on("files.info", () => ({
      file: {
        id: "F0NOTES0001",
        name: "notes.txt",
        mimetype: "text/plain",
        url_private_download: fileDownloadUrl
      }
    }))

    const result = await callSlackTool(connected, "download_file", { file: "F0NOTES0001" })

    expect(structured(result)).toEqual({
      id: "F0NOTES0001",
      name: "notes.txt",
      mimetype: "text/plain",
      size: fileText.length,
      path: "/tmp/codevisor-slack/F0NOTES0001/notes.txt",
      text: fileText
    })
  })
})

describe("posting", () => {
  it("refuses to post until the user approved it", async () => {
    const connected = await connectSlack()

    const result = await callSlackTool(connected, "post_message", {
      channel: "#eng",
      text: "hi",
      confirm: false
    })

    expect(result.isError).toBe(true)
    expect(toolText(result)).toContain("requires confirm: true")
    expect(connected.slack.called("chat.postMessage")).toEqual([])
  })

  it("DMs a person by handle and returns the message's link", async () => {
    const connected = await connectSlack()

    const result = await callSlackTool(connected, "post_message", {
      channel: "@sam",
      text: "Lunch?",
      confirm: true
    })

    expect(connected.slack.called("conversations.open")).toEqual([{ users: sam.id }])
    expect(connected.slack.called("chat.postMessage")).toEqual([
      { channel: samDm.id, text: "Lunch?" }
    ])
    expect(structured(result)).toEqual({
      posted: true,
      channel: samDm.id,
      ts: "1731350000.000200",
      link: "https://acme.slack.com/archives/D0SAM000001/p1731350000000200"
    })
  })

  it("replies in a thread and broadcasts only when asked", async () => {
    const connected = await connectSlack()

    await callSlackTool(connected, "post_message", {
      channel: eng.id,
      text: "Done",
      threadTs: "1731350001.000000",
      broadcast: true,
      confirm: true
    })

    expect(connected.slack.called("chat.postMessage")).toEqual([
      { channel: eng.id, text: "Done", thread_ts: "1731350001.000000", reply_broadcast: "true" }
    ])
  })

  it("schedules a message at the given time", async () => {
    const connected = await connectSlack()
    connected.slack.on("chat.scheduleMessage", (params) => ({
      channel: params.channel,
      scheduled_message_id: "Q123",
      post_at: Number(params.post_at)
    }))

    const result = await callSlackTool(connected, "schedule_message", {
      channel: "#eng",
      text: "Standup",
      postAt: "2026-11-12T09:00:00-08:00",
      confirm: true
    })

    expect(connected.slack.called("chat.scheduleMessage")[0]?.post_at).toBe("1794502800")
    expect(structured(result)).toEqual({
      scheduled: true,
      channel: eng.id,
      id: "Q123",
      postAt: "2026-11-12T17:00:00.000Z"
    })
  })

  it("uploads a local file through Slack's external upload flow", async () => {
    const connected = await connectSlack()
    connected.files.local.set("/Users/dana/report.csv", {
      name: "report.csv",
      bytes: new TextEncoder().encode("a,b\n")
    })
    connected.slack.on("files.getUploadURLExternal", () => ({
      upload_url: uploadUrl,
      file_id: "F0UP0000001"
    }))
    connected.slack.on("files.completeUploadExternal", () => ({ files: [] }))

    const result = await callSlackTool(connected, "upload_file", {
      channel: "#eng",
      path: "/Users/dana/report.csv",
      comment: "Numbers",
      confirm: true
    })

    expect(connected.slack.called("files.getUploadURLExternal")).toEqual([
      { filename: "report.csv", length: "4" }
    ])
    expect(new TextDecoder().decode(connected.slack.uploads[0])).toBe("a,b\n")
    expect(connected.slack.called("files.completeUploadExternal")).toEqual([
      {
        files: JSON.stringify([{ id: "F0UP0000001", title: "report.csv" }]),
        channel_id: eng.id,
        initial_comment: "Numbers"
      }
    ])
    expect(structured(result)).toEqual({ shared: true, file: "F0UP0000001", name: "report.csv" })
  })

  it("explains a missing permission", async () => {
    const connected = await connectSlack()
    connected.slack.on("reactions.add", () => ({
      ok: false,
      error: "missing_scope",
      needed: "reactions:write"
    }))

    const result = await callSlackTool(connected, "add_reaction", {
      channel: eng.id,
      ts: "1731350001.000000",
      emoji: ":eyes:"
    })

    expect(connected.slack.called("reactions.add")).toEqual([
      { channel: eng.id, timestamp: "1731350001.000000", name: "eyes" }
    ])
    expect(toolText(result)).toBe(
      "The Slack app is missing the reactions:write permission. Add it under OAuth & Permissions › User Token Scopes, then reinstall the app."
    )
  })
})
