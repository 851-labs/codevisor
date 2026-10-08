import { describe, expect, it } from "vitest"

import { jsonRequest, readWebSocketEvents, run, start } from "../test-support.js"

const at = (ms: number, device: string) => `${String(ms).padStart(13, "0")}-000000-${device}`
const folder = (revision: string, name: string) => ({
  id: "folder-payments",
  name,
  position: "8",
  collapsed: false,
  deleted: false,
  revision
})

describe("replicated navigation records", () => {
  it("keeps the newest write and wakes every connected client with it", async () => {
    const { server, services } = await start()
    const cursor = await run(services.db.latestEventCursor)
    const readers = [
      readWebSocketEvents(server, 2, cursor, "/v1/events/socket", true),
      readWebSocketEvents(server, 2, cursor, "/v1/events/socket", true)
    ]
    const put = (body: unknown) =>
      jsonRequest(server, "/v1/navigation/records", { method: "PUT", body: JSON.stringify(body) })

    expect(await put({ folders: [folder(at(2, "mac"), "Payments")] })).toEqual({
      status: 200,
      body: { folders: [folder(at(2, "mac"), "Payments")], settings: [] }
    })
    // Each socket opens with a keepalive, then the change.
    for (const events of await Promise.all(readers)) {
      expect(events).toEqual([
        expect.objectContaining({ kind: "keepalive" }),
        expect.objectContaining({
          kind: "navigation.changed",
          payload: expect.objectContaining({
            folders: [expect.objectContaining({ name: "Payments" })]
          })
        })
      ])
    }

    // A late copy of an older edit from another machine changes nothing.
    expect((await put({ folders: [folder(at(1, "ios"), "Old")] })).body).toMatchObject({
      folders: [{ name: "Payments" }]
    })
    expect(
      (
        await put({
          settings: [{ key: "sidebar.grouping", value: "project", revision: at(3, "ios") }]
        })
      ).status
    ).toBe(200)
    expect(await jsonRequest(server, "/v1/navigation/records")).toEqual({
      status: 200,
      body: {
        folders: [folder(at(2, "mac"), "Payments")],
        settings: [{ key: "sidebar.grouping", value: "project", revision: at(3, "ios") }]
      }
    })
    expect((await put({ folders: [{ ...folder("not-a-clock", "Bad") }] })).status).toBe(400)
    expect((await jsonRequest(server, "/v1/navigation/records", { method: "DELETE" })).status).toBe(
      404
    )
  })
})
