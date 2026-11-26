import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { createServer, type Server, type Socket } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { onTestFinished } from "vitest"

import type { ScalerCommands } from "./screen-sharing-vnc-scale.js"
import { SCREEN_SHARING_CONFIG_FILE } from "./screen-sharing-vnc.js"

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
