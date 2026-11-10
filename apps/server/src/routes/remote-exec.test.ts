import { randomUUID } from "node:crypto"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { archiveJobs } from "../archive-jobs.js"
import { makeExecTasks } from "../infra/exec-tasks.js"
import type { MachineLink } from "../infra/machine-link.js"
import { makeMirrorStore } from "../infra/mirror-store.js"
import { makeRemoteExecTasks } from "../infra/remote-exec-tasks.js"
import { makeWorkspaceSyncs } from "../infra/workspace-syncs.js"
import { jsonRequest, makeServices, startWithApp, tempDirs } from "../test-support.js"
import { field } from "./response-test-support.js"

const tempDir = (prefix: string): string => {
  const directory = mkdtempSync(join(tmpdir(), prefix))
  tempDirs.push(directory)
  return directory
}

const fakeMachines = (): MachineLink => ({
  list: async () => [],
  resolve: (machine) => {
    if (machine === "server-a") return "self"
    if (machine === "MacBook" || machine === "machine-mbp") {
      return { id: "machine-mbp", name: "MacBook", deviceId: "device-mbp" }
    }
    if (machine === "E2B box") {
      return { id: "machine-e2b", name: "E2B box", deviceId: "device-e2b", isSandbox: true }
    }
    return undefined
  },
  invoke: async () => undefined,
  machineIdOf: () => undefined,
  isGone: () => false
})

const execServer = async () => {
  const { services } = await makeServices("server-a")
  const execTasks = makeExecTasks({
    directory: tempDir("codevisor-exec-"),
    shell: "/bin/sh",
    env: process.env
  })
  const mirrors = makeMirrorStore(tempDir("codevisor-mirrors-"))
  const workspaceSyncs = makeWorkspaceSyncs({
    directory: tempDir("codevisor-sync-state-"),
    intervalMs: 3_600_000,
    transport: {
      prepare: (_machine, mirrorId, name) => mirrors.prepare(mirrorId, name, "server-a"),
      write: (_machine, mirrorId, offset, data) => mirrors.write(mirrorId, offset, data),
      apply: (_machine, mirrorId, commit, head) => mirrors.apply(mirrorId, commit, head),
      remove: (_machine, mirrorId) => mirrors.remove(mirrorId)
    }
  })
  onTestFinished(() => {
    execTasks.closeAll()
    workspaceSyncs.close()
  })
  const machines = fakeMachines()
  const remoteExecTasks = makeRemoteExecTasks({
    self: { id: "server-a", name: () => "Server A" },
    link: machines,
    local: execTasks
  })
  const running = { ...services, execTasks, remoteExecTasks, workspaceSyncs, mirrors, machines }
  const server = await startWithApp(running, undefined, { id: "server-a" })
  const call = (method: string, path: string, body?: unknown) =>
    jsonRequest(server, path, {
      method,
      ...(body === undefined ? {} : { body: JSON.stringify(body) })
    })
  return { call, execTasks, services: running }
}

const workspaceWithSession = async (call: Awaited<ReturnType<typeof execServer>>["call"]) => {
  const root = tempDir("codevisor-tasks-root-")
  const project = await call("POST", "/v1/projects", { folderPath: root })
  const projectId = field(project.body, "id")
  const created = await call("POST", "/v1/workspaces", {
    workspace: {
      id: randomUUID(),
      projectId,
      name: "Tasks",
      hasCustomName: true,
      rootDirectory: root
    },
    session: { projectId, harnessId: "codex", deferAgentSession: true }
  })
  return {
    workspaceId: String(field(field(created.body, "workspace"), "id")),
    sessionId: String(field(field(created.body, "session"), "id"))
  }
}

describe("remote exec routes", () => {
  it("runs commands in the foreground or background and reads files", async () => {
    const { call } = await execServer()
    const folder = tempDir("codevisor-exec-cwd-")
    writeFileSync(join(folder, "notes.txt"), "one\ntwo\nthree\n")

    const ran = await call("POST", "/v1/exec", { command: "cat notes.txt", cwd: folder })
    expect(ran.body).toMatchObject({ exitCode: 0, output: "one\ntwo\nthree\n", timedOut: false })

    const read = await call(
      "GET",
      `/v1/fs/read?path=${encodeURIComponent(join(folder, "notes.txt"))}&offset=2&limit=1`
    )
    expect(read.body).toMatchObject({ content: "2\ttwo", startLine: 2, endLine: 2, totalLines: 3 })

    const started = await call("POST", "/v1/exec", {
      command: "echo ready; sleep 30",
      run_in_background: true
    })
    const taskId = String(field(started.body, "taskId"))
    expect((await call("GET", `/v1/exec/tasks/${taskId}`)).body).toMatchObject({ state: "running" })
    expect((await call("GET", "/v1/exec/activity")).body).toMatchObject({ running: 1 })
    const stopped = await call("POST", `/v1/exec/tasks/${taskId}/stop`)
    expect(stopped.body).toMatchObject({ state: "stopped" })
    expect((await call("GET", "/v1/exec/activity")).body).toMatchObject({
      running: 0,
      lastActiveAt: expect.any(String)
    })
  })

  it("refuses commands it can't run", async () => {
    const { call } = await execServer()

    expect((await call("POST", "/v1/exec", { command: "  " })).status).toBe(400)
    expect((await call("POST", "/v1/exec", { command: "ls", cwd: "/nope/nowhere" })).status).toBe(
      400
    )
    expect((await call("GET", "/v1/exec/tasks/missing")).status).toBe(404)
    expect((await call("GET", "/v1/fs/read?path=%2Fnope%2Ffile")).status).toBe(404)
  })

  it("starts, reports, and stops a workspace sync", async () => {
    const { call } = await execServer()
    const root = tempDir("codevisor-sync-root-")
    writeFileSync(join(root, "index.html"), "<h1>hi</h1>")
    const project = await call("POST", "/v1/projects", { folderPath: root })
    const workspaceId = randomUUID()
    await call("PUT", `/v1/workspaces/${workspaceId}`, {
      projectId: field(project.body, "id"),
      name: "Site",
      hasCustomName: true,
      rootDirectory: root,
      isArchived: false
    })
    const syncs = `/v1/workspaces/${workspaceId}/syncs`

    expect((await call("POST", syncs, { machine: "server-a" })).status).toBe(400)
    expect((await call("POST", syncs, { machine: "Nowhere" })).status).toBe(404)
    expect((await call("POST", syncs, { machine: "E2B box" })).body).toMatchObject({
      code: "sandbox_target"
    })
    expect((await call("POST", syncs, { machine: "MacBook" })).body).toMatchObject({
      machine: { machineId: "machine-mbp", name: "MacBook" }
    })
    const status = await call("GET", `${syncs}/machine-mbp`)
    expect(status.status).toBe(200)
    expect((await call("GET", syncs)).body).toMatchObject({ items: [{ workspaceId }] })

    expect((await call("DELETE", `${syncs}/machine-mbp`)).body).toEqual({ stopped: true })
    expect((await call("GET", `${syncs}/machine-mbp`)).status).toBe(404)
    expect((await call("GET", "/v1/sessions/missing/syncs")).status).toBe(409)
  })

  it("lists a workspace's background commands, reads their output, and stops them", async () => {
    const { call } = await execServer()
    const { workspaceId, sessionId } = await workspaceWithSession(call)

    const started = await call("POST", "/v1/exec", {
      command: "echo first; echo second; sleep 30",
      description: "Dev server",
      run_in_background: true,
      callerAgentId: sessionId
    })
    const taskId = String(field(started.body, "taskId"))
    const tasks = `/v1/workspaces/${workspaceId}/exec-tasks`
    expect((await call("GET", tasks)).body).toMatchObject({
      items: [{ taskId, sessionId, description: "Dev server", machine: { machineId: "server-a" } }]
    })
    expect((await call("GET", `/v1/workspaces/${randomUUID()}/exec-tasks`)).body).toEqual({
      items: []
    })
    expect((await call("GET", `${tasks}/${taskId}/output`)).status).toBe(200)

    expect((await call("POST", `${tasks}/${taskId}/stop`)).status).toBe(204)
    expect((await call("GET", tasks)).body).toEqual({ items: [] })
    expect((await call("POST", `${tasks}/${taskId}/stop`)).status).toBe(404)
  })
  it("stops a workspace's background commands when it's archived", async () => {
    const { call, execTasks, services } = await execServer()
    const { workspaceId, sessionId } = await workspaceWithSession(call)
    const started = await call("POST", "/v1/exec", {
      command: "sleep 30",
      description: "Dev server",
      run_in_background: true,
      callerAgentId: sessionId
    })
    const taskId = String(field(started.body, "taskId"))

    const archived = await call("PATCH", `/v1/workspaces/${workspaceId}`, { isArchived: true })
    expect(archived.status).toBe(200)
    await archiveJobs(services).idle()

    expect(execTasks.get(taskId)?.state).toBe("stopped")
    expect((await call("GET", `/v1/workspaces/${workspaceId}/exec-tasks`)).body).toEqual({
      items: []
    })
  })
})
