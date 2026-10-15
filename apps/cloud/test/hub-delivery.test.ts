import { describe, expect, it, vi } from "vitest"

import { deliverToMachine } from "../src/hub-delivery.js"
import { ResumeSessions, type ResumeSessionRow } from "../src/resume-sessions.js"
import {
  closingSocket,
  insertMachine,
  machineRow,
  taggedSockets,
  withHubStorage
} from "./hub-port-test-support.js"

describe("hub relay delivery fallback", () => {
  it("retires a closing current socket and buffers the frame for resume", async () => {
    const row = machineRow({ active_generation: 7 })
    const session: ResumeSessionRow = {
      connection_id: "connection-1",
      kind: "machine",
      device_id: row.device_id,
      public_key: row.public_key,
      resume_token_hash: "hash",
      expires_at: Date.now() + 60_000
    }
    const message = new Uint8Array([1, 2, 3])

    await withHubStorage((sql) => {
      insertMachine(sql, row)
      const socket = closingSocket({
        kind: "machine",
        connectionId: "connection-1",
        deviceId: row.device_id,
        machineGeneration: row.active_generation,
        helloDone: true
      })
      const net = taggedSockets(new Map([[socket, [`machine:${row.device_id}`]]]))
      const send = vi.spyOn(net, "send")
      const resume = new ResumeSessions(sql, 60_000)
      vi.spyOn(resume, "machineGraceSession").mockReturnValue(session)
      const buffer = vi.spyOn(resume, "buffer").mockReturnValue(true)
      const retire = vi.fn<(socket: WebSocket) => void>()

      expect(deliverToMachine({ net, resume, sql, retire }, row.device_id, message)).toBe(true)
      expect(send).toHaveBeenCalledWith(socket, message)
      expect(retire).toHaveBeenCalledWith(socket)
      expect(buffer).toHaveBeenCalledWith(session.connection_id, message)
    })
  })
})
