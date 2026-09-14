import { startCommand, type CliDeps } from "./support.js"

export interface CloudRegistration {
  readonly deviceId?: string
  readonly serverUrl?: string
  readonly state?: string
  readonly managedBy?: "app" | "external"
}

export const cloudUrl = (port: number): string => `http://127.0.0.1:${port}/v1/cloud`

export const readCloudRegistration = async (
  deps: CliDeps,
  port: number
): Promise<CloudRegistration | undefined> => {
  const response = await deps.fetchJson(cloudUrl(port))
  if (response === undefined) return undefined
  if (response.status !== 200 || response.body === null || typeof response.body !== "object") {
    throw new Error(
      `Cannot read Cloud state from the server on port ${port} (status ${response.status}). Update the server and retry.`
    )
  }
  return response.body as CloudRegistration
}

export const ensureCloudServer = async (
  deps: CliDeps,
  port: number
): Promise<CloudRegistration> => {
  const running = await readCloudRegistration(deps, port)
  if (running !== undefined) return running
  if ((await startCommand(deps, { port })) !== 0) {
    throw new Error(`Could not start the Codevisor server on port ${port}`)
  }
  const started = await readCloudRegistration(deps, port)
  if (started === undefined) throw new Error(`Codevisor server on port ${port} is unavailable`)
  return started
}

/// Connection success means this device completed the relay handshake. The
/// registration API also reports a device while connecting or revoked.
export const waitForCloudConnection = async (
  deps: CliDeps,
  port: number,
  deviceId: string
): Promise<void> => {
  const timeoutMs = 30_000
  const intervalMs = 500
  for (let elapsed = 0; ; elapsed += intervalMs) {
    const registration = await readCloudRegistration(deps, port)
    if (registration?.deviceId !== deviceId) {
      throw new Error("The server's Cloud registration changed or the server stopped during login")
    }
    if (registration.state === "connected") return
    if (registration.state === "revoked" || registration.state === "unsupported-protocol") {
      throw new Error(`Cloud connection failed: ${registration.state}`)
    }
    if (elapsed >= timeoutMs) {
      throw new Error(
        `Cloud credentials are saved, but the relay is ${registration.state ?? "not connected"}. Check codevisor auth status and codevisor logs.`
      )
    }
    await deps.sleep(intervalMs)
  }
}
