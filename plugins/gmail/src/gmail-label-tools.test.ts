import { toolText } from "@codevisor/plugin-kit/test-support"
import { describe, expect, it } from "vitest"
import { z } from "zod"

import { callTool, connectGmail } from "./gmail-test-support.js"

const red = { backgroundColor: "#fb4c2f", textColor: "#ffffff" }

const labelList = z.object({ labels: z.array(z.object({ name: z.string() })) })

const labelRequests = (connected: Awaited<ReturnType<typeof connectGmail>>) =>
  connected.gmail.requests
    .filter((request) => request.method !== "GET")
    .map((request) => ({
      method: request.method,
      path: request.url.pathname.split("/").slice(-2).join("/"),
      body: request.body
    }))

const labelNames = async (connected: Awaited<ReturnType<typeof connectGmail>>) => {
  const listed = await callTool(connected, "list_labels", {})
  return labelList.parse(listed.structuredContent).labels.map((label) => label.name)
}

describe("gmail labels", () => {
  it("creates a label with a color and visibility, then applies it by name", async () => {
    const connected = await connectGmail()
    connected.gmail.add({ id: "m1", labels: ["INBOX"] })

    const created = await callTool(connected, "create_label", {
      name: " AI ",
      color: red,
      labelListVisibility: "labelShowIfUnread"
    })
    await callTool(connected, "modify_labels", { messageIds: ["m1"], add: ["ai"] })

    expect(created.structuredContent).toEqual({
      label: {
        id: "Label_5",
        name: "AI",
        type: "user",
        color: red,
        labelListVisibility: "labelShowIfUnread"
      }
    })
    expect(labelRequests(connected)[0]).toEqual({
      method: "POST",
      path: "me/labels",
      body: { name: "AI", color: red, labelListVisibility: "labelShowIfUnread" }
    })
    expect(connected.gmail.labelsOf("m1")).toEqual(["INBOX", "Label_5"])
  })

  it("renames and recolors a label by name, sending only the changed settings", async () => {
    const connected = await connectGmail()

    const updated = await callTool(connected, "update_label", {
      label: "receipts",
      name: "Finance/Receipts",
      color: red
    })

    expect(updated.structuredContent).toEqual({
      label: { id: "Label_1", name: "Finance/Receipts", type: "user", color: red }
    })
    expect(labelRequests(connected)).toEqual([
      { method: "PATCH", path: "labels/Label_1", body: { name: "Finance/Receipts", color: red } }
    ])
  })

  it("deletes a label by name", async () => {
    const connected = await connectGmail()

    const deleted = await callTool(connected, "delete_label", { label: "Receipts" })

    expect(deleted.structuredContent).toEqual({ deleted: { id: "Label_1", name: "Receipts" } })
    expect(labelRequests(connected)).toEqual([
      { method: "DELETE", path: "labels/Label_1", body: undefined }
    ])
    expect(await labelNames(connected)).toEqual(["INBOX", "UNREAD", "STARRED"])
  })

  it("refuses to change or delete system labels without calling Gmail", async () => {
    const connected = await connectGmail()

    const renamed = await callTool(connected, "update_label", { label: "inbox", name: "Mail" })
    const deleted = await callTool(connected, "delete_label", { label: "STARRED" })

    expect(toolText(renamed)).toBe(
      "INBOX is a Gmail system label; only your own labels can change."
    )
    expect(toolText(deleted)).toBe(
      "STARRED is a Gmail system label; only your own labels can change."
    )
    expect(labelRequests(connected)).toEqual([])
  })

  it("explains missing changes, unknown labels and Gmail's name conflicts", async () => {
    const connected = await connectGmail()

    const noChange = await callTool(connected, "update_label", { label: "Receipts" })
    const unknown = await callTool(connected, "delete_label", { label: "Taxes" })
    const taken = await callTool(connected, "create_label", { name: "receipts" })

    expect(toolText(noChange)).toContain("Give a new name, color or visibility.")
    expect(toolText(unknown)).toBe(
      'Unknown label "Taxes". Call list_labels to see the label names, or create_label to add it.'
    )
    expect(toolText(taken)).toBe("Gmail returned 409: Label name exists or conflicts")
    expect(await labelNames(connected)).toEqual(["INBOX", "UNREAD", "STARRED", "Receipts"])
  })

  it("marks delete_label destructive and the other label writes as safe", async () => {
    const { client } = await connectGmail()

    const { tools } = await client.listTools()
    const destructive = tools.filter((tool) => tool.annotations?.destructiveHint)

    expect(destructive.map((tool) => tool.name)).toEqual(["delete_label"])
  })
})
