import Database from "better-sqlite3"
import { expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

it("adds the Codevisor MCP kind without losing existing providers, credentials, or scope settings", async () => {
  const filename = tempDatabase()
  const current = await run(makeDatabase({ filename, serverId: "local" }))
  let expected
  let projectId: string
  let sessionId: string
  try {
    const project = await run(current.createProject({ folderPath: "/tmp/mcp-upgrade" }))
    const session = await run(current.createSession({ projectId: project.id, harnessId: "codex" }))
    projectId = project.id
    sessionId = session.id
    for (const [id, kind] of [
      ["browser", "browserUse"],
      ["computer", "computerUse"],
      ["external", "managed"]
    ] as const) {
      await run(
        current.saveMcpServer({
          id,
          kind,
          name: id,
          transport: "stdio",
          command: "example-mcp",
          args: ["--test"],
          enabled: true,
          authType: "none",
          connectionState: "disconnected",
          toolCount: 1,
          secretCipher: "preserved-ciphertext"
        })
      )
    }
    await run(current.setProjectMcpEnabled(project.id, "browser", false))
    await run(current.setSessionMcpEnabled(session.id, "computer", false))
    expected = await run(current.listMcpServers)
  } finally {
    await run(current.close)
  }

  const legacy = new Database(filename)
  try {
    legacy.exec(`
      alter table mcp_servers add column old_kind text not null default 'managed'
        check(old_kind in ('managed', 'browserUse', 'computerUse'));
      update mcp_servers set old_kind = kind;
      alter table mcp_servers drop column kind;
      alter table mcp_servers rename column old_kind to kind;
      delete from schema_migrations where id = 46;
    `)
  } finally {
    legacy.close()
  }

  const upgraded = await run(makeDatabase({ filename, serverId: "local" }))
  try {
    expect(await run(upgraded.listMcpServers)).toEqual(expected)
    const resolved = await run(upgraded.resolveMcpServers(projectId, sessionId))
    expect(resolved.find((server) => server.id === "browser")?.enabled).toBe(false)
    expect(resolved.find((server) => server.id === "computer")?.enabled).toBe(false)
    expect(resolved.find((server) => server.id === "external")?.enabled).toBe(true)
    expect(
      await run(
        upgraded.saveMcpServer({
          id: "codevisor",
          kind: "codevisor",
          name: "Codevisor",
          transport: "stdio",
          args: [],
          enabled: true,
          authType: "none",
          connectionState: "connected",
          toolCount: 1
        })
      )
    ).toMatchObject({ kind: "codevisor", canEdit: false, canRemove: false })
    expect(await run(upgraded.migrate)).toEqual([])
  } finally {
    await run(upgraded.close)
  }
})
