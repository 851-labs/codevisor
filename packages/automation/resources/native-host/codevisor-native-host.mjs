import { createHmac, randomBytes, timingSafeEqual } from "node:crypto"
import { readFileSync } from "node:fs"
import { join } from "node:path"

import {
  encodeNativeMessage,
  frameMessages,
  HOST_TO_BROWSER_CHUNK_CHARACTERS,
  makeFrameAssembler,
  makeNativeMessageReader
} from "./native-messaging.mjs"

const PROTOCOL_VERSION = 1
const DEFAULT_SERVER_PORT = 49361
const HANDSHAKE_TIMEOUT_MS = 10_000
const SOCKET_PATH = "/v1/browser-use/extension/native"

const dataDir = process.argv[2]
let nextChunkId = 0
let serverSocket
let bridgedSocket

const sendToBrowser = (value) => process.stdout.write(encodeNativeMessage(value))

const exitAfterFlush = () => process.stdout.end(() => process.exit(0))

const fail = (cause) => {
  sendToBrowser({ type: "unavailable", reason: failureReason(cause) })
  exitAfterFlush()
}

const failureReason = (cause) => (cause instanceof Error ? cause.message : String(cause))

const serverPort = () => {
  try {
    const port = JSON.parse(readFileSync(join(dataDir, "server-port.json"), "utf8")).port
    return Number.isInteger(port) && port > 0 && port <= 65_535 ? port : DEFAULT_SERVER_PORT
  } catch {
    return DEFAULT_SERVER_PORT
  }
}

const hostSecret = () =>
  readFileSync(join(dataDir, "browser", "native-host", "secret"), "utf8").trim()

const proof = (secret, role, first, second) =>
  createHmac("sha256", secret).update(`${role}\n${first}\n${second}`).digest("hex")

const proofMatches = (expected, actual) =>
  typeof actual === "string" &&
  actual.length === expected.length &&
  timingSafeEqual(Buffer.from(actual), Buffer.from(expected))

const parsedFrame = (event) => {
  try {
    return JSON.parse(String(event.data))
  } catch {
    return undefined
  }
}

const authenticate = (socket, secret) =>
  new Promise((resolve, reject) => {
    const nonce = randomBytes(32).toString("hex")
    let challenge
    const timeout = setTimeout(
      () => reject(new Error("Codevisor did not finish the native host handshake")),
      HANDSHAKE_TIMEOUT_MS
    )
    const onMessage = (event) => {
      const frame = parsedFrame(event)
      if (challenge === undefined && frame?.type === "challenge") {
        challenge = String(frame.nonce)
        socket.send(
          JSON.stringify({
            type: "auth",
            nonce,
            proof: proof(secret, "codevisor-native-host", challenge, nonce)
          })
        )
        return
      }
      clearTimeout(timeout)
      socket.removeEventListener("message", onMessage)
      const expected = proof(secret, "codevisor-server", nonce, challenge ?? "")
      if (frame?.type === "ready" && proofMatches(expected, frame.proof)) resolve(socket)
      else reject(new Error("Codevisor did not prove it owns this data directory"))
    }
    socket.addEventListener("message", onMessage)
    socket.addEventListener("close", () => {
      clearTimeout(timeout)
      reject(new Error("Codevisor closed the native host connection"))
    })
  })

const openServerSocket = (port) =>
  new Promise((resolve, reject) => {
    const socket = new WebSocket(`ws://127.0.0.1:${port}${SOCKET_PATH}`)
    socket.addEventListener("open", () => resolve(socket), { once: true })
    socket.addEventListener(
      "error",
      () => reject(new Error(`Codevisor is not running on port ${port}`)),
      {
        once: true
      }
    )
  })

const bridge = (socket) => {
  socket.addEventListener("message", (event) => {
    const frames = frameMessages(
      String(event.data),
      HOST_TO_BROWSER_CHUNK_CHARACTERS,
      () => (nextChunkId += 1)
    )
    for (const frame of frames) sendToBrowser(frame)
  })
  socket.addEventListener("close", exitAfterFlush)
  bridgedSocket = socket
  sendToBrowser({ type: "connected" })
}

const assemble = makeFrameAssembler()
process.stdin.on(
  "data",
  makeNativeMessageReader((message) => {
    const text = assemble(message)
    if (text !== undefined && bridgedSocket?.readyState === WebSocket.OPEN) bridgedSocket.send(text)
  })
)
process.stdin.on("end", () => {
  serverSocket?.close()
  process.exit(0)
})

sendToBrowser({ type: "hello", version: PROTOCOL_VERSION })
try {
  const secret = hostSecret()
  serverSocket = await openServerSocket(serverPort())
  await authenticate(serverSocket, secret)
  bridge(serverSocket)
} catch (cause) {
  serverSocket?.close()
  fail(cause)
}
