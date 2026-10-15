import { decodeHubToApp, encodeRelayEnvelopes } from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"

import { abandonSession } from "../src/hub-notices.js"
import { ResumeSessions, type ResumeSessionRow } from "../src/resume-sessions.js"
import {
  insertMachine,
  machineRow,
  openSocket,
  taggedSockets,
  withHubStorage
} from "./hub-port-test-support.js"

describe("abandoned machine session", () => {
  it("fails buffered channels even while the machine is connected under another session", async () => {
    const row = machineRow({ active_generation: 3 })
    const expired: ResumeSessionRow = {
      connection_id: "machine-before",
      kind: "machine",
      device_id: row.device_id,
      public_key: row.public_key,
      resume_token_hash: "hash",
      expires_at: 1
    }
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

    await withHubStorage((sql) => {
      insertMachine(sql, row)
      const machineSocket = openSocket({
        kind: "machine",
        connectionId: "machine-now",
        deviceId: row.device_id,
        machineGeneration: row.active_generation,
        helloDone: true
      })
      const appSocket = openSocket({ kind: "app", connectionId: "app-1", helloDone: true })
      const net = taggedSockets(
        new Map([
          [machineSocket, ["machine", `machine:${row.device_id}`]],
          [appSocket, ["app"]]
        ])
      )
      vi.spyOn(net, "send").mockImplementation((socket, encoded) => {
        if (typeof encoded !== "string") throw new Error("expected a JSON control frame")
        sent.push({ socket, frame: decodeHubToApp(encoded) })
        return true
      })
      const broadcastMachineNotice = vi.spyOn(net, "broadcastMachineNotice")
      const resume = new ResumeSessions(sql, 60_000)
      vi.spyOn(resume, "drainBuffers").mockReturnValue(buffered)
      const remove = vi.spyOn(resume, "delete")

      abandonSession({ net, resume, sql }, expired)

      expect(remove).toHaveBeenCalledWith("machine-before")
      expect(broadcastMachineNotice).not.toHaveBeenCalled()
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
})
