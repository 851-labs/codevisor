import type { CloudSocket } from "@codevisor/cloud-client"
import type { IncomingMessage, ServerResponse } from "node:http"
import { networkInterfaces } from "node:os"
import type { WebSocket } from "ws"
import { writeJson, type CodevisorServerConfig } from "../server-context.js"

/// The direct-path discovery surface: apps ask (over the E2E relay) where
/// this machine can be reached on its local networks, probe the candidates,
/// and open sealed channels straight to /v1/direct when one answers — same
/// channel protocol, no hub round trip. Requires the standard bearer/loopback
/// authorization like every data route; the relay path arrives via loopback.

export interface DirectPathInfo {
  /// This machine's cloud device id — the address inside relay headers, and
  /// how the app matches the answer to its pinned identity. Null when the
  /// machine has no cloud registration (then there is nothing to pair with).
  deviceId: string | null
  port: number
  /// LAN addresses worth probing. Empty when the server only listens on
  /// loopback (no direct path possible).
  hosts: string[]
}

/// Non-internal IPv4 addresses; link-local (169.254/16) excluded.
export const directHosts = (
  bindHost: string,
  interfaces: () => Record<string, { address: string; family: string; internal: boolean }[]>
): string[] => {
  if (bindHost === "127.0.0.1" || bindHost === "localhost") return []
  const hosts: string[] = []
  for (const entries of Object.values(interfaces())) {
    for (const entry of entries) {
      if (entry.internal || entry.family !== "IPv4") continue
      if (entry.address.startsWith("169.254.")) continue
      hosts.push(entry.address)
    }
  }
  return hosts
}

export const routeNetDirect = (
  config: CodevisorServerConfig,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): boolean => {
  if (request.method !== "GET" || url.pathname !== "/v1/net/direct") return false
  const deviceId =
    (config.cloud === undefined ? config.cloudDeviceId : config.cloud.deviceId()) ?? null
  const info: DirectPathInfo = {
    deviceId,
    port: config.port,
    hosts:
      deviceId === null || !config.directPathEnabled
        ? []
        : directHosts(
            config.host,
            networkInterfaces as unknown as () => Record<
              string,
              { address: string; family: string; internal: boolean }[]
            >
          )
  }
  writeJson(response, 200, info)
  return true
}

/// Adapts a server-accepted `ws` socket onto the CloudSocket surface the
/// DirectChannelHost consumes (mirror of cloud-bridge's outbound adapter).
export const adaptDirectSocket = (socket: WebSocket): CloudSocket => {
  const adapted: CloudSocket = {
    send: (data) => socket.send(data),
    close: (code, reason) => socket.close(code, reason),
    terminate: () => socket.terminate(),
    onopen: null,
    onmessage: null,
    onclose: null
  }
  socket.on("message", (data, isBinary) => {
    if (isBinary) {
      const bytes = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer)
      adapted.onmessage?.(new Uint8Array(bytes))
      return
    }
    adapted.onmessage?.(String(data))
  })
  socket.on("close", (code) => adapted.onclose?.(code))
  socket.on("error", () => undefined) // close fires afterwards
  return adapted
}
