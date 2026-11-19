import {
  decode,
  FileMetadata,
  FLEET_SANDBOX_CHATS_PATH,
  SavedChatFileChunk,
  SavedChatItem,
  SavedChatList,
  type SandboxChatsAction
} from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { jsonRequest, run, waitFor } from "../test-support.js"
import {
  invokeAs,
  laptop,
  post,
  startFleet,
  stranger,
  studio,
  type FleetMachine,
  type Member
} from "./fleet-test-support.js"
import { field } from "./response-test-support.js"

const workspaceId = "5f0b6a52-6f0e-4a44-9d39-1b7f2d3c4e5a"
const paneId = "9a1c2b3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d"
const reviewPaneId = "9a1c2b3d-4e5f-4a6b-8c7d-0e1f2a3b4c5e"
const terminalPaneId = "9a1c2b3d-4e5f-4a6b-8c7d-0e1f2a3b4c5f"

const asking =
  (from: FleetMachine, self: Member, target: Member) =>
  (action: SandboxChatsAction): Promise<unknown> =>
    from.machines.invoke(target.id, FLEET_SANDBOX_CHATS_PATH, action, {
      machineId: self.id,
      machineName: self.name
    })

const uploaded = async (machine: FleetMachine, text: string): Promise<FileMetadata> => {
  const response = await fetch(`${machine.server.url}/v1/files?name=notes.txt`, {
    method: "POST",
    headers: { "content-type": "text/plain" },
    body: text
  })
  return decode(FileMetadata)(await response.json())
}

const chattedOn = async (machine: FleetMachine, projectId: string) => {
  const file = await uploaded(machine, "kept with the chat")
  const created = await post(machine, "/v1/sessions", {
    projectId,
    harnessId: "codex",
    title: "Fix the laptop",
    workspaceId
  })
  const sessionId = String(field(created.body, "id"))
  await post(
    machine,
    `/v1/workspaces/${workspaceId}/panes/${paneId}`,
    {
      providerId: "codevisor",
      paneType: "chat",
      title: "Fix the laptop",
      resourceKind: "session",
      resourceId: sessionId
    },
    "PUT"
  )
  await post(
    machine,
    `/v1/workspaces/${workspaceId}/panes/${reviewPaneId}`,
    { providerId: "codevisor", paneType: "review", title: "Review Changes" },
    "PUT"
  )
  await post(
    machine,
    `/v1/workspaces/${workspaceId}/panes/${terminalPaneId}`,
    {
      providerId: "codevisor",
      paneType: "terminal",
      title: "Terminal 1",
      resourceKind: "terminal",
      resourceId: "t1"
    },
    "PUT"
  )
  const { id: fileId, name, mimeType, sizeBytes, kind } = file
  await post(machine, `/v1/sessions/${sessionId}/prompt`, {
    text: "hello",
    attachments: [{ fileId, name, mimeType, sizeBytes, kind }]
  })
  await waitFor(async () => {
    const page = await run(machine.services.db.getTranscriptPage(sessionId, undefined, 8))
    return page.items.some((item) => item.text === "Echo: hello")
  })
  return { sessionId, file }
}

const transcriptOn = async (machine: FleetMachine, sessionId: string) => {
  const page = await run(machine.services.db.getTranscriptPage(sessionId, undefined, 8))
  return page.items.map((item) => [item.id, item.role, item.text, item.attachments?.[0]?.fileId])
}

const movedToStudio = async () => {
  const fleet = await startFleet()
  const { home, remote } = fleet
  const chat = await chattedOn(remote, "laptop-project")
  const before = await transcriptOn(remote, chat.sessionId)
  const fromLaptop = asking(home, studio, laptop)
  const toStudio = asking(remote, laptop, studio)
  const list = decode(SavedChatList)(await fromLaptop({ action: "list", workspaceId }))
  await post(
    home,
    `/v1/workspaces/${workspaceId}`,
    { projectId: "home-project", name: "Restored box", hasCustomName: false },
    "PUT"
  )
  return { ...fleet, chat, before, fromLaptop, toStudio, list }
}

describe("moving a sandbox's chats between machines", () => {
  it("hands over each chat with its history, attachment and tabs, and takes them back whole, even when each step is sent twice", async () => {
    const { home, chat, before, fromLaptop, toStudio: once, list } = await movedToStudio()
    const toStudio = async (action: SandboxChatsAction): Promise<unknown> => {
      await once(action)
      return once(action)
    }
    const [saved] = list.chats
    if (saved === undefined) throw new Error("The laptop listed no chats")
    const { format } = list
    const sessionId = saved.session.id

    const { session } = saved
    await toStudio({ action: "restore_chat", format, workspaceId, session, hidden: true })
    const midway = await jsonRequest(home.server, `/v1/sessions/${sessionId}`)
    for (const itemId of saved.itemIds) {
      const item = decode(SavedChatItem)(await fromLaptop({ action: "item", itemId }))
      await toStudio({ action: "restore_item", format, sessionId, item })
    }
    for (const file of saved.files) {
      const read = { action: "file", fileId: file.id, offset: 0, length: 1024 } as const
      const { data } = decode(SavedChatFileChunk)(await fromLaptop(read))
      await toStudio({ action: "restore_file", file, offset: 0, data })
    }
    const fileIds = saved.files.map((file) => file.id)
    const restore = {
      startedAt: "2026-11-16T00:01:00.000Z",
      completedAt: "2026-11-16T00:01:40.000Z",
      lines: ["==> Creating the sandbox"]
    }
    await toStudio({ action: "finish_chat", format, sessionId, fileIds, workspaceId, restore })
    for (const pane of list.panes)
      await toStudio({ action: "restore_pane", format, workspaceId, pane })

    expect(field(midway.body, "session")).not.toHaveProperty("workspaceId")
    expect(saved.session).toMatchObject({ id: chat.sessionId, title: "Fix the laptop" })
    expect(saved.files).toEqual([chat.file])
    expect(await transcriptOn(home, sessionId)).toEqual(before)
    const page = await run(home.services.db.getTranscriptPage(sessionId, undefined, 8))
    expect(
      page.setupActivities.filter((line) => field(line, "kind") === "sandbox.restore")
    ).toHaveLength(1)
    const restored = await jsonRequest(home.server, `/v1/sessions/${sessionId}`)
    expect(field(restored.body, "session")).toMatchObject({
      title: "Fix the laptop",
      workspaceId,
      projectId: "home-project"
    })
    const attachment = await fetch(`${home.server.url}/v1/files/${chat.file.id}`)
    expect(await attachment.text()).toBe("kept with the chat")
    const panes = await run(home.services.db.listWorkspacePanes)
    expect(panes.filter((pane) => pane.workspaceId === workspaceId)).toMatchObject([
      { id: paneId, workspaceId, resourceId: sessionId },
      { id: reviewPaneId, workspaceId, paneType: "review" }
    ])
  })

  it("refuses chats saved in a format it doesn't read, and callers outside the account", async () => {
    const { home, toStudio, list } = await movedToStudio()
    const [saved] = list.chats
    if (saved === undefined) throw new Error("The laptop listed no chats")
    const restore = { action: "restore_chat", workspaceId, session: saved.session } as const

    const newer = await toStudio({ ...restore, format: list.format + 1 }).catch(
      (cause: unknown) => cause
    )
    const outsider = await invokeAs(stranger, home, {
      path: FLEET_SANDBOX_CHATS_PATH,
      args: { action: "list", workspaceId },
      origin: { machineId: stranger.id, machineName: stranger.name }
    })

    expect(String(newer)).toContain(
      "These chats were saved in format 2, and this sandbox's Codevisor reads format 1"
    )
    expect(outsider.status).toBe(403)
    expect(await run(home.services.db.listSessions)).toHaveLength(1)
  })
})
