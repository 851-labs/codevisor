const NATIVE_RELAY_CONNECTING = 0
const NATIVE_RELAY_OPEN = 1
const NATIVE_RELAY_CLOSED = 3
const BROWSER_TO_HOST_CHUNK_CHARACTERS = 8 * 1024 * 1024

class CodevisorNativeRelay {
  constructor(hostName) {
    this.hostName = hostName
    this.readyState = NATIVE_RELAY_CONNECTING
    this.hostResponded = false
    this.failure = undefined
    this.listeners = new Map()
    this.pendingChunks = new Map()
    this.nextChunkId = 0
    this.port = chrome.runtime.connectNative(hostName)
    this.port.onMessage.addListener((message) => this.receive(message))
    this.port.onDisconnect.addListener(() =>
      this.finish(chrome.runtime.lastError?.message ?? "The Codevisor native host disconnected")
    )
  }

  get hostMissing() {
    return !this.hostResponded
  }

  addEventListener(type, listener) {
    const listeners = this.listeners.get(type) ?? new Set()
    listeners.add(listener)
    this.listeners.set(type, listeners)
  }

  send(text) {
    if (this.readyState !== NATIVE_RELAY_OPEN) return
    if (text.length <= BROWSER_TO_HOST_CHUNK_CHARACTERS) {
      // oxlint-disable-next-line unicorn/require-post-message-target-origin
      this.port.postMessage(text)
      return
    }
    const id = (this.nextChunkId += 1)
    const count = Math.ceil(text.length / BROWSER_TO_HOST_CHUNK_CHARACTERS)
    for (let index = 0; index < count; index += 1) {
      const start = index * BROWSER_TO_HOST_CHUNK_CHARACTERS
      const data = text.slice(start, start + BROWSER_TO_HOST_CHUNK_CHARACTERS)
      // oxlint-disable-next-line unicorn/require-post-message-target-origin
      this.port.postMessage({ type: "chunk", id, index, count, data })
    }
  }

  close() {
    if (this.readyState === NATIVE_RELAY_CLOSED) return
    this.port.disconnect()
    this.finish(undefined)
  }

  receive(message) {
    this.hostResponded = true
    if (typeof message === "string") {
      this.emit("message", { data: message })
      return
    }
    if (message?.type === "chunk") {
      this.receiveChunk(message)
      return
    }
    if (message?.type === "connected") {
      this.readyState = NATIVE_RELAY_OPEN
      this.emit("open", {})
      return
    }
    if (message?.type === "unavailable") this.failure = message.reason
  }

  receiveChunk(message) {
    const parts = this.pendingChunks.get(message.id) ?? []
    parts[message.index] = message.data
    if (message.index < message.count - 1) {
      this.pendingChunks.set(message.id, parts)
      return
    }
    this.pendingChunks.delete(message.id)
    this.emit("message", { data: parts.join("") })
  }

  finish(reason) {
    if (this.readyState === NATIVE_RELAY_CLOSED) return
    this.readyState = NATIVE_RELAY_CLOSED
    this.failure ??= reason
    this.pendingChunks.clear()
    this.emit("close", {})
  }

  emit(type, event) {
    for (const listener of this.listeners.get(type) ?? []) listener(event)
  }
}

globalThis.openCodevisorNativeRelay = (hostName) => {
  if (typeof hostName !== "string" || hostName === "") return undefined
  if (typeof chrome.runtime.connectNative !== "function") return undefined
  return new CodevisorNativeRelay(hostName)
}
