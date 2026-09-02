import { describe, expect, it, vi } from "vitest"
import { deliverToMachine, type HubDeliveryPort } from "../src/hub-delivery.js"
import type { MachineRow, SocketAttachment } from "../src/hub-schema.js"
import type { ResumeSessionRow } from "../src/resume-sessions.js"

describe("hub relay delivery fallback", () => {
  it("retires a closing current socket and buffers the frame for resume", () => {
    const socket = { readyState: WebSocket.CLOSING } as WebSocket
    const row: MachineRow = {
      device_id: "machine-1",
      name: "Machine",
      os: "macOS",
      app_version: "1",
      public_key: "key",
      last_seen_at: "now",
      active_generation: 7
    }
    const attachment: SocketAttachment = {
      kind: "machine",
      connectionId: "connection-1",
      deviceId: row.device_id,
      machineGeneration: row.active_generation,
      helloDone: true
    }
    const session: ResumeSessionRow = {
      connection_id: attachment.connectionId,
      kind: "machine",
      device_id: row.device_id,
      public_key: row.public_key,
      resume_token_hash: "hash",
      expires_at: Date.now() + 60_000
    }
    const send = vi.fn(() => false)
    const retire = vi.fn()
    const buffer = vi.fn(() => true)
    const port = {
      sql: { exec: () => ({ toArray: () => [row] }) },
      net: {
        machine: () => [socket],
        attachment: () => attachment,
        send
      },
      resume: {
        machineGraceSession: () => session,
        buffer
      },
      retire
    } as unknown as HubDeliveryPort
    const message = new Uint8Array([1, 2, 3])

    expect(deliverToMachine(port, row.device_id, message)).toBe(true)
    expect(send).toHaveBeenCalledWith(socket, message)
    expect(retire).toHaveBeenCalledWith(socket)
    expect(buffer).toHaveBeenCalledWith(session.connection_id, message)
  })
})
