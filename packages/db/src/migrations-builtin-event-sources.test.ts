import Database from "better-sqlite3"
import { expect, it } from "vitest"

import { makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const rewindBuiltinEventSourcesSql = `
  create table plugin_event_subscriptions_old (
    id text primary key,
    session_id text not null references sessions(id) on delete cascade,
    server_id text not null references mcp_servers(id) on delete cascade,
    account_id text,
    event_name text not null,
    arguments text not null default '{}',
    filter text,
    explained text not null,
    note text,
    once integer not null default 0,
    created_by text not null check(created_by in ('agent', 'user')),
    paused_reason text,
    created_at text not null
  );
  insert into plugin_event_subscriptions_old select * from plugin_event_subscriptions;
  drop table plugin_event_subscriptions;
  alter table plugin_event_subscriptions_old rename to plugin_event_subscriptions;
  create table plugin_events_old (
    id text primary key,
    server_id text not null references mcp_servers(id) on delete cascade,
    account_id text not null default '',
    event_name text not null,
    source_event_id text not null,
    occurred_at text not null,
    received_at text not null,
    data text not null,
    unique(server_id, account_id, event_name, source_event_id)
  );
  insert into plugin_events_old select * from plugin_events;
  drop table plugin_events;
  alter table plugin_events_old rename to plugin_events;
  delete from schema_migrations where id = 108;
`

const subscribe = (db: CodevisorDatabaseService, sessionId: string, serverId: string) =>
  run(
    db.createPluginEventSubscription({
      sessionId,
      serverId,
      eventName: "ping",
      arguments: {},
      explained: "every event",
      once: false,
      createdBy: "agent"
    })
  )

it("keeps plugin subscriptions and pending events, accepts a built-in source, and still clears a deleted plugin's", async () => {
  const filename = tempDatabase()
  const current = await run(makeDatabase({ filename, serverId: "local" }))
  let sessionId: string
  let expected
  try {
    const project = await run(current.createProject({ folderPath: "/tmp/builtin-events" }))
    const session = await run(current.createSession({ projectId: project.id, harnessId: "codex" }))
    sessionId = session.id
    await run(
      current.saveMcpServer({
        id: "pinger",
        kind: "managed",
        name: "Pinger",
        transport: "stdio",
        command: "pinger",
        enabled: true,
        authType: "none",
        connectionState: "disconnected",
        toolCount: 0
      })
    )
    const subscription = await subscribe(current, sessionId, "pinger")
    const recorded = await run(
      current.recordPluginEvent({
        serverId: "pinger",
        eventName: "ping",
        sourceEventId: "e1",
        occurredAt: "2026-11-13T17:00:00.000Z",
        data: { message: "hi" }
      })
    )
    await run(current.addPluginEventDelivery(subscription.id, recorded.event.id))
    expected = {
      subscriptions: await run(current.listPluginEventSubscriptions()),
      pending: await run(current.pendingPluginEventDeliveries)
    }
  } finally {
    await run(current.close)
  }

  const legacy = new Database(filename)
  try {
    legacy.pragma("foreign_keys = OFF")
    legacy.exec(rewindBuiltinEventSourcesSql)
  } finally {
    legacy.close()
  }

  const upgraded = await run(makeDatabase({ filename, serverId: "local" }))
  try {
    expect({
      subscriptions: await run(upgraded.listPluginEventSubscriptions()),
      pending: await run(upgraded.pendingPluginEventDeliveries)
    }).toEqual(expected)

    const clock = await subscribe(upgraded, sessionId, "codevisor.clock")
    await run(upgraded.deleteMcpServer("pinger"))

    expect(await run(upgraded.listPluginEventSubscriptions())).toEqual([clock])
    expect(await run(upgraded.pendingPluginEventDeliveries)).toEqual([])
    expect(await run(upgraded.recentPluginEvents("pinger", "ping", 10))).toEqual([])
  } finally {
    await run(upgraded.close)
  }
})
