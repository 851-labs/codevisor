import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { createServer, type Server, type Socket } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { expect, onTestFinished } from "vitest"
import type { RawData, WebSocket } from "ws"

import { jsonRequest, makeServices, startWithApp } from "../test-support.js"
import type { ScalerCommands } from "./screen-sharing-vnc-scale.js"
import { SCREEN_SHARING_CONFIG_FILE, VNC_DISPLAY_ID } from "./screen-sharing-vnc.js"
import { fileVNCDesktops } from "./vnc-desktops.js"

export interface FakeVNC {
  readonly server: Server
  readonly socket: string
  readonly connections: Socket[]
}

const ownerOnly = 0o600

export const privateDirectory = (): string => {
  const directory = mkdtempSync(join(tmpdir(), "cv-vnc-"))
  onTestFinished(() => rmSync(directory, { recursive: true, force: true }))
  return directory
}

export const listenPrivately = async (server: Server, directory: string): Promise<string> => {
  const socket = join(directory, "d.sock")
  await new Promise<void>((resolve) => server.listen(socket, resolve))
  chmodSync(socket, ownerOnly)
  return socket
}

export const fakeVNC = async (directory: string = privateDirectory()): Promise<FakeVNC> => {
  const connections: Socket[] = []
  const server = createServer((connection) => {
    connections.push(connection)
    connection.write("RFB 003.008\n")
    connection.on("data", (chunk) => connection.write(chunk))
  })
  const socket = await listenPrivately(server, directory)
  onTestFinished(async () => {
    for (const connection of connections) connection.destroy()
    if (server.listening) await new Promise<void>((resolve) => server.close(() => resolve()))
  })
  return { server, socket, connections }
}

export const writeDesktopConfig = (dataDir: string, vnc: Record<string, unknown>): void =>
  writeFileSync(join(dataDir, SCREEN_SHARING_CONFIG_FILE), JSON.stringify({ vnc }))

export const recordingSession = (): {
  readonly commands: ScalerCommands
  readonly environments: Record<string, string>[]
} => {
  const environments: Record<string, string>[] = []
  const commands: ScalerCommands = {
    run: async (command, _args, env) => {
      if (command === "pgrep") return "4242\n"
      environments.push(env)
      return "1\n"
    },
    spawnDetached: async () => undefined,
    environ: () => "HOME=/home/codevisor\0DBUS_SESSION_BUS_ADDRESS=unix:path=/run/bus\0"
  }
  return { commands, environments }
}

const bytesOf = (data: RawData): Buffer =>
  Array.isArray(data) ? Buffer.concat(data) : Buffer.from(new Uint8Array(data))

export const nextMessage = (socket: WebSocket): Promise<Buffer> =>
  new Promise((resolve, reject) => {
    socket.once("message", (data) => resolve(bytesOf(data)))
    socket.once("error", reject)
    socket.once("close", (code) => reject(new Error(`closed ${code}`)))
  })

export const closed = (socket: WebSocket): Promise<number> =>
  new Promise((resolve) => socket.once("close", resolve))

export const closure = (socket: WebSocket): Promise<{ code: number; reason: string }> =>
  new Promise((resolve) =>
    socket.once("close", (code, reason) => resolve({ code, reason: reason.toString() }))
  )

export const statusOf = (socket: WebSocket) =>
  new Promise<number>((resolve) => {
    socket.once("unexpected-response", (_request, response) => resolve(response.statusCode ?? 0))
    socket.once("error", () => undefined)
  })

const identity = {
  workspaceId: "0b0f4a52-6a4f-4f0a-9a43-0d0b2f6d7c11",
  paneId: "0b0f4a52-6a4f-4f0a-9a43-0d0b2f6d7c12",
  viewerId: "0b0f4a52-6a4f-4f0a-9a43-0d0b2f6d7c13",
  app: { key: "a".repeat(64), name: "Studio Mac" }
}

export const sharesAScreen = { features: expect.arrayContaining(["screen-sharing-v1"]) }
export const streamsAgentViews = { features: expect.arrayContaining(["computer-use-stream-v1"]) }

export const startWithDesktop = async (
  vnc?: Record<string, unknown>,
  auth?: { allowLocalhostWithoutAuth: boolean; requireBearerToken: boolean },
  commands?: ScalerCommands,
  log?: (line: string) => void
) => {
  const dataDir = privateDirectory()
  if (vnc !== undefined) writeDesktopConfig(dataDir, vnc)
  const { services } = await makeServices()
  const desktops = fileVNCDesktops(dataDir, {
    ...(commands === undefined ? {} : { commands }),
    ...(log === undefined ? {} : { log })
  })
  const server = await startWithApp(services, undefined, {
    desktops,
    ...(auth === undefined ? {} : { auth })
  })
  const socketUrl = (displayId: string = VNC_DISPLAY_ID) =>
    `ws://127.0.0.1:${server.port}/v1/screen-sharing/vnc/socket?displayId=${displayId}`
  const ask = (request: Record<string, unknown>) =>
    jsonRequest(server, "/v1/screen-sharing", {
      method: "POST",
      body: JSON.stringify({ version: 1, ...identity, ...request })
    })
  const capabilities = () => ask({ operation: "capabilities" })
  const info = async (): Promise<unknown> => (await jsonRequest(server, "/v1/info")).body
  return { services, server, socketUrl, ask, capabilities, info, dataDir, desktops }
}
