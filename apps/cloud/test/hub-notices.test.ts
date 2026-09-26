import { decodeHubToApp, encodeRelayEnvelopes } from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"

import { abandonSession, type HubNoticesPort } from "../src/hub-notices.js"
import type { MachineRow, SocketAttachment } from "../src/hub-schema.js"
import type { ResumeSessionRow } from "../src/resume-sessions.js"

describe("abandoned machine session", () => {
  it("fails buffered channels even while the machine is connected under another session", () => {
    const row: MachineRow = {
      device_id: "machine-1",
      name: "Machine",
      os: "macOS",
      app_version: "1",
      public_key: "key",
      last_seen_at: "now",
      active_generation: 3,
      server_id: null,
      peer_aware: 0
    }
    const machineSocket = { readyState: WebSocket.OPEN } as WebSocket
    const appSocket = { readyState: WebSocket.OPEN } as WebSocket
    const attachments = new Map<WebSocket, SocketAttachment>([
      [
        machineSocket,
        {
          kind: "machine",
          connectionId: "machine-now",
          deviceId: row.device_id,
          machineGeneration: row.active_generation,
          helloDone: true
        }
      ],
      [appSocket, { kind: "app", connectionId: "app-1", helloDone: true }]
    ])
    const expired: ResumeSessionRow = {
      connection_id: "machine-before",
      kind: "machine",
      device_id: row.device_id,
      public_key: row.public_key,
      resume_token_hash: "hash",
      expires_at: 1
    }
    // Two frames on one channel and a close on another were buffered.
    const buffered = [
      encodeRelayEnvelopes([
        {
          header: {
            peerId: "app-1",
            frame: { t: "open", channelId: "ch-1", seq: 0, ephemeralKey: "k" }
          },
          payload: new Uint8Array([1])
        },
        {
          header: { peerId: "app-1", frame: { t: "credit", channelId: "ch-1", seq: 1, bytes: 8 } },
          payload: new Uint8Array()
        }
      ]),
      encodeRelayEnvelopes([
        {
          header: {
            peerId: "app-1",
            frame: { t: "close", channelId: "ch-2", seq: 4, reason: "done" }
          },
          payload: new Uint8Array()
        }
      ])
    ]
    const sent: { socket: WebSocket; frame: unknown }[] = []
    const remove = vi.fn()
    const port = {
      sql: { exec: () => ({ toArray: () => [row] }) },
      net: {
        machine: () => [machineSocket],
        attachment: (socket: WebSocket) => attachments.get(socket),
        isRoutable: (socket: WebSocket) => attachments.get(socket)?.helloDone === true,
        byConnectionId: (id: string) =>
          [...attachments].filter(([, a]) => a.connectionId === id).map(([socket]) => socket),
        byTag: () => [],
        broadcastMachineNotice: vi.fn(),
        broadcastToPeerMachines: vi.fn(),
        send: (socket: WebSocket, encoded: string) => {
          sent.push({ socket, frame: decodeHubToApp(encoded) })
          return true
        }
      },
      resume: { drainBuffers: () => buffered, delete: remove }
    } as unknown as HubNoticesPort

    abandonSession(port, expired)

    expect(remove).toHaveBeenCalledWith("machine-before")
    // Connected under its new session: no machine-wide offline notice...
    expect(port.net.broadcastMachineNotice).not.toHaveBeenCalled()
    // ...but the opener learns its channel's frames are gone, once.
    expect(sent).toEqual([
      {
        socket: appSocket,
        frame: {
          t: "error",
          code: "machine-offline",
          message: "machine relay delivery failed",
          machineId: row.device_id,
          channelId: "ch-1"
        }
      }
    ])
  })
})
