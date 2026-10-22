import { createHmac, randomBytes, timingSafeEqual } from "node:crypto"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"

export const NATIVE_HOST_NAME = "com.codevisor.host"
export const NATIVE_HOST_HANDSHAKE_TIMEOUT_MS = 10_000

export interface NativeHostSocket {
  send(data: string): void
  close(code?: number, reason?: string): void
  on(event: "message", listener: (data: unknown) => void): unknown
  once(event: "close", listener: () => void): unknown
  off(event: "message", listener: (data: unknown) => void): unknown
  off(event: "close", listener: () => void): unknown
}

export const nativeHostNameFor = (worktreeName: string | undefined): string => {
  const worktree = worktreeName
    ?.trim()
    .toLowerCase()
    .replace(/[^a-z0-9_]+/g, "_")
  if (worktree === undefined || worktree === "") return NATIVE_HOST_NAME
  return `com.codevisor.dev.${worktree}`
}

export const nativeHostDirectory = (dataDir: string): string =>
  join(dataDir, "browser", "native-host")

export const ensureNativeHostSecret = (dataDir: string): string => {
  const existing = readNativeHostSecret(dataDir)
  if (existing !== undefined) return existing

  const secret = randomBytes(32).toString("hex")
  mkdirSync(nativeHostDirectory(dataDir), { recursive: true, mode: 0o700 })
  writeFileSync(secretPath(dataDir), `${secret}\n`, { mode: 0o600 })
  return secret
}

export const readNativeHostSecret = (dataDir: string): string | undefined => {
  const path = secretPath(dataDir)
  if (!existsSync(path)) return undefined
  const secret = readFileSync(path, "utf8").trim()
  return secret === "" ? undefined : secret
}

export const authenticateNativeHost = (
  socket: NativeHostSocket,
  secret: string,
  timeoutMs: number = NATIVE_HOST_HANDSHAKE_TIMEOUT_MS
): Promise<boolean> =>
  new Promise((resolve) => {
    const challenge = randomBytes(32).toString("hex")
    const finish = (authenticated: boolean) => {
      clearTimeout(timeout)
      socket.off("message", onMessage)
      socket.off("close", onClose)
      if (!authenticated) socket.close(1008, "Codevisor native host authentication failed")
      resolve(authenticated)
    }
    const onMessage = (data: unknown) => {
      const reply = hostReply(data)
      if (reply === undefined || !hostProofMatches(secret, challenge, reply)) {
        finish(false)
        return
      }
      socket.send(readyFrame(secret, challenge, reply.nonce))
      finish(true)
    }
    const onClose = () => finish(false)
    const timeout = setTimeout(() => finish(false), timeoutMs)
    socket.on("message", onMessage)
    socket.once("close", onClose)
    socket.send(JSON.stringify({ type: "challenge", nonce: challenge }))
  })

export const nativeHostProof = (
  secret: string,
  role: "codevisor-native-host" | "codevisor-server",
  first: string,
  second: string
): string => createHmac("sha256", secret).update(`${role}\n${first}\n${second}`).digest("hex")

interface HostReply {
  readonly nonce: string
  readonly proof: string
}

const secretPath = (dataDir: string): string => join(nativeHostDirectory(dataDir), "secret")

const hostReply = (data: unknown): HostReply | undefined => {
  try {
    const frame: unknown = JSON.parse(String(data))
    if (!isHostReply(frame)) return undefined
    return { nonce: frame.nonce, proof: frame.proof }
  } catch {
    return undefined
  }
}

const isHostReply = (
  frame: unknown
): frame is { readonly type: "auth"; readonly nonce: string; readonly proof: string } =>
  typeof frame === "object" &&
  frame !== null &&
  "type" in frame &&
  frame.type === "auth" &&
  "nonce" in frame &&
  typeof frame.nonce === "string" &&
  "proof" in frame &&
  typeof frame.proof === "string"

const hostProofMatches = (secret: string, challenge: string, reply: HostReply): boolean => {
  const expected = Buffer.from(
    nativeHostProof(secret, "codevisor-native-host", challenge, reply.nonce)
  )
  const actual = Buffer.from(reply.proof)
  return actual.length === expected.length && timingSafeEqual(actual, expected)
}

const readyFrame = (secret: string, challenge: string, nonce: string): string =>
  JSON.stringify({
    type: "ready",
    proof: nativeHostProof(secret, "codevisor-server", nonce, challenge)
  })
