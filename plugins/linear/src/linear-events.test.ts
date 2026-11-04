import { anyResult } from "@codevisor/plugin-kit/test-support"
import type { Notification } from "@modelcontextprotocol/server"
import { describe, expect, it } from "vitest"

import { linearStreamLifetimeMs } from "./linear-push.js"
import {
  accountFor,
  type ConnectedLinear,
  connectLinear,
  done,
  fakeIssue,
  me,
  meUrl,
  openLinearStream,
  ping,
  routedMeta,
  sam,
  todo
} from "./linear-test-support.js"

const receive = (connected: ConnectedLinear, overrides: Record<string, unknown>) =>
  connected.client.request({ method: "codevisor/webhook", params: ping(overrides) }, anyResult)

const eventsOf = (notifications: ReadonlyArray<Notification>) =>
  notifications
    .filter((notification) => notification.method === "notifications/events/event")
    .map((notification) => notification.params)

const delivered = (connected: ConnectedLinear, subscriptionId: unknown) =>
  eventsOf(connected.inbox.forSubscription(subscriptionId))

const issuePayload = {
  id: "issue-1",
  identifier: "ENG-1",
  title: "Launch checklist",
  url: "https://linear.app/acme/issue/ENG-1/launch-checklist",
  priority: 2,
  priorityLabel: "High",
  status: done,
  team: { id: "team-eng", key: "ENG", name: "Engineering" },
  project: { id: "project-1", name: "Launch" },
  assignee: me,
  creator: sam,
  labels: ["Bug"],
  createdAt: "2026-11-04T19:00:00.000Z",
  updatedAt: "2026-11-04T20:00:00.000Z"
}

describe("linear events", () => {
  it("declares push events over a routed ingress with typed payloads", async () => {
    const { client } = await connectLinear()

    const listed = await client.request({ method: "events/list" }, anyResult)

    expect(client.getServerCapabilities()?.extensions).toMatchObject({
      "dev.codevisor/webhooks": { ingress: [{ name: "linear", route: "linear" }] }
    })
    expect(listed.events).toMatchObject(
      ["issue.created", "issue.updated", "comment.created", "mention.created"].map((name) => ({
        name,
        delivery: ["push"],
        payloadSchema: { type: "object" }
      }))
    )
  })

  it("opens a stream only with a signed-in account and the cloud's Linear route", async () => {
    const { client } = await connectLinear()
    const stream = (meta: Record<string, unknown>) =>
      client.request(
        {
          method: "events/stream",
          params: { name: "issue.created", arguments: {}, cursor: null, _meta: meta }
        },
        anyResult
      )

    await expect(stream(accountFor())).rejects.toMatchObject({ code: -32026 })
    await expect(stream({})).rejects.toMatchObject({ code: -32024 })
    await expect(stream(routedMeta("lin_oauth_revoked"))).rejects.toMatchObject({ code: -32024 })
  })

  it("fires comment.created, and mention.created when someone else mentions the account", async () => {
    const connected = await connectLinear()
    const issue = fakeIssue()
    connected.linear.comments.set("comment-1", {
      id: "comment-1",
      body: `[@Dana](${meUrl}) can you take a look?`,
      url: `${issue.url}#comment-1`,
      createdAt: "2026-11-04T20:00:00.000Z",
      user: sam,
      issue
    })
    const comments = await openLinearStream(connected, "comment.created")
    const mentions = await openLinearStream(connected, "mention.created")

    const outcome = await receive(connected, { type: "Comment", action: "create", id: "comment-1" })

    expect(outcome).toEqual({ accepted: 2, status: 200 })
    expect(delivered(connected, comments.subscriptionId)).toMatchObject([
      {
        eventId: "comment.created:comment:comment-1",
        name: "comment.created",
        timestamp: "2026-11-04T20:00:00.000Z",
        data: {
          comment: { id: "comment-1", url: `${issue.url}#comment-1` },
          author: sam,
          issue: issuePayload,
          byMe: false,
          mentionsMe: true,
          assignedToMe: true
        }
      }
    ])
    expect(delivered(connected, mentions.subscriptionId)).toMatchObject([
      {
        eventId: "mention.created:comment:comment-1",
        data: { source: "comment", author: sam, comment: { id: "comment-1" }, issue: issuePayload }
      }
    ])
  })

  it("doesn't count the account's own comments or look-alike profiles as mentions", async () => {
    const connected = await connectLinear()
    const comment = {
      url: "https://linear.app/acme/issue/ENG-1#c",
      createdAt: "2026-11-04T20:00:00.000Z",
      issue: fakeIssue()
    }
    connected.linear.comments.set("own", {
      ...comment,
      id: "own",
      body: `note to ${meUrl}`,
      user: me
    })
    connected.linear.comments.set("other", {
      ...comment,
      id: "other",
      body: `${meUrl}a2 hi`,
      user: sam
    })
    const comments = await openLinearStream(connected, "comment.created")
    const mentions = await openLinearStream(connected, "mention.created")

    await receive(connected, { type: "Comment", action: "create", id: "own" })
    await receive(connected, { type: "Comment", action: "create", id: "other" })

    expect(
      delivered(connected, comments.subscriptionId).map((event) => [event?.["data"]])
    ).toMatchObject([[{ byMe: true, mentionsMe: true }], [{ byMe: false, mentionsMe: false }]])
    expect(delivered(connected, mentions.subscriptionId)).toEqual([])
  })

  it("fires issue.created, and a mention when a teammate's new issue mentions the account", async () => {
    const connected = await connectLinear()
    connected.linear.issues.set("issue-1", fakeIssue({ description: `Owner: ${meUrl}` }))
    const created = await openLinearStream(connected, "issue.created")
    const mentions = await openLinearStream(connected, "mention.created")

    await receive(connected, { type: "Issue", action: "create", id: "issue-1", actorId: sam.id })

    expect(delivered(connected, created.subscriptionId)).toEqual([
      {
        eventId: "issue.created:issue:issue-1",
        name: "issue.created",
        timestamp: "2026-11-04T20:00:00.000Z",
        data: { issue: issuePayload, actor: sam, byMe: false, assignedToMe: true },
        cursor: null,
        _meta: expect.any(Object)
      }
    ])
    expect(delivered(connected, mentions.subscriptionId)).toMatchObject([
      {
        eventId: "mention.created:issue:issue-1",
        data: { source: "issue", comment: null, author: sam }
      }
    ])
  })

  it("fires issue.updated with what changed and the previous status, assignee and priority", async () => {
    const connected = await connectLinear()
    connected.linear.issues.set("issue-1", fakeIssue({ project: null }))
    const updated = await openLinearStream(connected, "issue.updated")

    await receive(connected, {
      type: "Issue",
      action: "update",
      id: "issue-1",
      updatedAt: "2026-11-04T20:00:00.000Z",
      actorId: sam.id,
      changed: ["stateId", "assigneeId", "priority", "title", "updatedAt", "sortOrder"],
      previous: { stateId: todo.id, assigneeId: null, priority: 0 }
    })

    expect(delivered(connected, updated.subscriptionId)).toMatchObject([
      {
        eventId: "issue.updated:issue:issue-1:2026-11-04T20:00:00.000Z",
        data: {
          issue: { ...issuePayload, project: null },
          changes: ["assignee", "priority", "status", "title"],
          from: { status: todo, assignee: null, priority: 0 },
          actor: sam,
          byMe: false,
          assignedToMe: true
        }
      }
    ])
  })

  it("skips updates that change nothing a person would notice, without calling Linear", async () => {
    const connected = await connectLinear()
    const updated = await openLinearStream(connected, "issue.updated")
    connected.linear.graphqlCalls.length = 0

    const outcome = await receive(connected, {
      type: "Issue",
      action: "update",
      id: "issue-1",
      changed: ["sortOrder", "updatedAt"]
    })

    expect(outcome).toEqual({ accepted: 0, status: 200 })
    expect(connected.linear.graphqlCalls).toEqual([])
    expect(delivered(connected, updated.subscriptionId)).toEqual([])
  })

  it("ignores pings it can't use: no open stream, another workspace, or an issue the account can't see", async () => {
    const connected = await connectLinear()
    const idle = await receive(connected, { type: "Issue", action: "create", id: "issue-1" })
    const created = await openLinearStream(connected, "issue.created")
    connected.linear.graphqlCalls.length = 0

    const elsewhere = await receive(connected, {
      type: "Issue",
      action: "create",
      id: "issue-1",
      organizationId: "org-other"
    })
    const hidden = await receive(connected, { type: "Issue", action: "create", id: "private-1" })

    expect([idle, elsewhere, hidden]).toEqual([
      { accepted: 0, status: 200 },
      { accepted: 0, status: 200 },
      { accepted: 0, status: 200 }
    ])
    expect(connected.linear.graphqlCalls).toEqual(["Issue"])
    expect(delivered(connected, created.subscriptionId)).toEqual([])
  })

  it("answers bad, unknown-ingress and failed deliveries with an error status", async () => {
    const connected = await connectLinear()
    await openLinearStream(connected, "issue.created")
    const unknownIngress = {
      ...ping({ type: "Issue", action: "create", id: "issue-1" }),
      ingress: "other"
    }
    const malformed = ping({ type: "Issue", action: "create", id: "issue-1" })
    malformed.request.body = Buffer.from("not json").toString("base64")

    const outcomes = [
      await connected.client.request(
        { method: "codevisor/webhook", params: unknownIngress },
        anyResult
      ),
      await connected.client.request({ method: "codevisor/webhook", params: malformed }, anyResult)
    ]
    connected.linear.failGraphql(500)
    outcomes.push(await receive(connected, { type: "Issue", action: "create", id: "issue-1" }))

    expect(outcomes).toEqual([
      { accepted: 0, status: 404 },
      { accepted: 0, status: 400 },
      { accepted: 0, status: 502 }
    ])
  })

  it("ends a stream after its lifetime so the host reopens it with a fresh account", async () => {
    const connected = await connectLinear()
    const stream = await openLinearStream(connected, "issue.created")

    connected.clock.advance(linearStreamLifetimeMs)

    await expect(stream.closed).resolves.toEqual({
      _meta: { "io.modelcontextprotocol/subscriptionId": stream.subscriptionId }
    })
    expect(connected.clock.timers()).toBe(0)
  })

  it("revokes the account's Linear token when the account is removed", async () => {
    const connected = await connectLinear()

    await connected.client.request(
      { method: "codevisor/account/remove", params: { _meta: accountFor() } },
      anyResult
    )

    expect(connected.linear.revoked).toEqual(["lin_oauth_test_token"])
  })
})
