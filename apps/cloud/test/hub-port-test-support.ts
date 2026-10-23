import { env, runInDurableObject } from "cloudflare:test"
import { vi } from "vitest"

import type { MachineRow, SocketAttachment } from "../src/hub-schema.js"
import { HubSockets } from "../src/hub-sockets.js"

export const openSocket = (attachment?: SocketAttachment): WebSocket => {
  const [, server] = Object.values(new WebSocketPair())
  if (server === undefined) throw new Error("WebSocketPair returned no server socket")
  server.accept()
  if (attachment !== undefined) server.serializeAttachment(attachment)
  return server
}

export const closingSocket = (attachment?: SocketAttachment): WebSocket => {
  const socket = openSocket(attachment)
  vi.spyOn(socket, "readyState", "get").mockReturnValue(WebSocket.CLOSING)
  return socket
}

export const taggedSockets = (tagged: ReadonlyMap<WebSocket, readonly string[]>): HubSockets =>
  new HubSockets({
    getWebSockets: (tag?: string) =>
      [...tagged].filter(([, tags]) => tag === undefined || tags.includes(tag)).map(([s]) => s)
  })

export const machineRow = (overrides: Partial<MachineRow> = {}): MachineRow => ({
  device_id: "machine-1",
  name: "Machine",
  os: "macOS",
  app_version: "1",
  public_key: "key",
  last_seen_at: "now",
  active_generation: 0,
  server_id: null,
  peer_aware: 0,
  tunnel_endpoint_id: null,
  tunnel_addr: null,
  display_name: null,
  icon: null,
  reported_icon: null,
  added_by_device_id: null,
  added_by_name: null,
  ephemeral_provider: null,
  ...overrides
})

export const withHubStorage = async <Result>(
  callback: (sql: SqlStorage) => Result | Promise<Result>
): Promise<Result> =>
  runInDurableObject(
    env.USER_HUB.get(env.USER_HUB.idFromName(crypto.randomUUID())),
    (_hub, state) => callback(state.storage.sql)
  )

export const insertMachine = (sql: SqlStorage, row: MachineRow): void => {
  sql.exec(
    `INSERT INTO machines
       (device_id, name, os, app_version, public_key, last_seen_at, active_generation, server_id,
        peer_aware, tunnel_endpoint_id, tunnel_addr)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    row.device_id,
    row.name,
    row.os,
    row.app_version,
    row.public_key,
    row.last_seen_at,
    row.active_generation,
    row.server_id,
    row.peer_aware,
    row.tunnel_endpoint_id,
    row.tunnel_addr
  )
}
