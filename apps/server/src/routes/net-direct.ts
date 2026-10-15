import type { IncomingMessage, ServerResponse } from "node:http"
import { networkInterfaces } from "node:os"

import type { CloudSocket } from "@codevisor/cloud-client"
import type { RawData } from "ws"

import { writeJson, type CodevisorServerConfig } from "../server-context.js"
import { liveCloudDeviceId } from "./cloud.js"

export interface DirectPathInfo {
  deviceId: string | null
  port: number
  hosts: string[]
}

export const directHosts = (
  bindHost: string,
  interfaces: () => NodeJS.Dict<
    ReadonlyArray<{ readonly address: string; readonly family: string; readonly internal: boolean }>
  >
): string[] => {
  if (bindHost === "127.0.0.1" || bindHost === "localhost") return []
  const hosts: string[] = []
  for (const entries of Object.values(interfaces())) {
    for (const entry of entries ?? []) {
      if (entry.internal || entry.family !== "IPv4") continue
      if (entry.address.startsWith("169.254.")) continue
      hosts.push(entry.address)
    }
  }
  return hosts
}

export const routeNetDirect = (
  config: CodevisorServerConfig,
  request: Pick<IncomingMessage, "method">,
  response: ServerResponse,
  url: URL
): boolean => {
  if (request.method !== "GET" || url.pathname !== "/v1/net/direct") return false
  const deviceId = liveCloudDeviceId(config) ?? null
  const info: DirectPathInfo = {
    deviceId,
    port: config.port,
    hosts:
      deviceId === null || !config.directPathEnabled
        ? []
        : directHosts(config.host, networkInterfaces)
  }
  writeJson(response, 200, info)
  return true
}

export interface DirectSocket {
  readonly send: (data: string | Uint8Array) => void
  readonly close: (code?: number, reason?: string) => void
  readonly terminate: () => void
  readonly on: {
    (event: "message", listener: (data: RawData, isBinary: boolean) => void): unknown
    (event: "close", listener: (code: number) => void): unknown
    (event: "error", listener: () => void): unknown
  }
}

export const adaptDirectSocket = (socket: DirectSocket): CloudSocket => {
  const adapted: CloudSocket = {
    send: (data) => socket.send(data),
    close: (code, reason) => socket.close(code, reason),
    terminate: () => socket.terminate(),
    onopen: null,
    onmessage: null,
    onclose: null
  }
  socket.on("message", (data, isBinary) => {
    try {
      const bytes = Buffer.concat(Array.isArray(data) ? data : [new Uint8Array(data)])
      adapted.onmessage?.(isBinary ? new Uint8Array(bytes) : bytes.toString())
    } catch {
      socket.close(1011, "message handler failed")
    }
  })
  socket.on("close", (code) => adapted.onclose?.(code))
  socket.on("error", () => undefined)
  return adapted
}
