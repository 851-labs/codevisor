importScripts("relay-config.js")

const connections = new Set()
const CODEVISOR_RELAY = globalThis.CODEVISOR_RELAY
const RECONNECT_ALARM = "codevisor-reconnect"
const RECONNECT_BASE_DELAY_MS = 1_000
const RECONNECT_MAX_DELAY_MS = 30_000
const CONNECT_TIMEOUT_MS = 10_000
let reconnectTimer
let activeSocket
let reconnectAttempt = 0
let reconnectScheduleGeneration = 0
let connectionState = "connecting"
let nextReconnectAt
let lastConnectedAt
let lastDisconnectedAt
let lastConnectionError
let lastCommandError
let lastCommandErrorAt
let offscreenCreation

const tabUrl = (tab) => tab.url || tab.pendingUrl || "about:blank"
const fileName = (path) =>
  String(path || "")
    .split(/[\\/]/)
    .at(-1) || "download"

const ensureOffscreenDocument = async () => {
  if (await chrome.offscreen.hasDocument()) return
  offscreenCreation ??= chrome.offscreen
    .createDocument({
      url: "offscreen.html",
      reasons: ["CLIPBOARD"],
      justification: "Read and write the clipboard for Codevisor Browser Use."
    })
    .finally(() => {
      offscreenCreation = undefined
    })
  await offscreenCreation
}

const runClipboardCommand = async (method, params) => {
  await ensureOffscreenDocument()
  const response = await chrome.runtime.sendMessage({
    target: "codevisor-offscreen",
    method,
    params
  })
  if (response?.ok !== true) {
    throw new Error(response?.error || "The Codevisor clipboard operation failed")
  }
  return response.result ?? {}
}

const tabTarget = (tab) => ({
  targetId: String(tab.id),
  type: "page",
  title: tab.title ?? "",
  url: tabUrl(tab)
})

class CodevisorConnection {
  constructor(socket, initialTabIds) {
    this.socket = socket
    this.allowedTabs = new Set(initialTabIds)
    this.sessionToTab = new Map()
    this.tabToSession = new Map()
    this.childSessionToTab = new Map()
    this.pendingDownloads = []
    this.downloadSessions = new Map()
    this.closed = false
    this.onDebuggerEvent = (source, method, params) => {
      if (source.tabId === undefined) return
      const sessionId = this.tabToSession.get(source.tabId)
      if (sessionId === undefined) return
      const childSessionId = params?.sessionId
      if (method === "Target.attachedToTarget" && typeof childSessionId === "string") {
        this.childSessionToTab.set(childSessionId, source.tabId)
      } else if (method === "Target.detachedFromTarget" && typeof childSessionId === "string") {
        this.childSessionToTab.delete(childSessionId)
      }
      this.send({ method, params, sessionId: source.sessionId || sessionId })
    }
    this.onDebuggerDetach = (source, reason) => {
      if (source.tabId === undefined) return
      const sessionId = this.tabToSession.get(source.tabId)
      if (sessionId === undefined) return
      this.tabToSession.delete(source.tabId)
      this.sessionToTab.delete(sessionId)
      for (const [childSessionId, tabId] of this.childSessionToTab) {
        if (tabId === source.tabId) this.childSessionToTab.delete(childSessionId)
      }
      this.send({ method: "Target.detachedFromTarget", params: { sessionId, reason } })
    }
    this.onTabCreated = (tab) => {
      if (tab.id === undefined || tab.openerTabId === undefined) return
      if (!this.allowedTabs.has(tab.openerTabId)) return
      this.allowedTabs.add(tab.id)
      this.send({ method: "Target.targetCreated", params: { targetInfo: tabTarget(tab) } })
    }
    this.onTabRemoved = (tabId) => {
      if (!this.allowedTabs.delete(tabId)) return
      this.send({ method: "Target.targetDestroyed", params: { targetId: String(tabId) } })
    }
    this.onDownloadCreated = (item) => void this.handleDownloadCreated(item)
    this.onDownloadChanged = (delta) => void this.handleDownloadChanged(delta)
    chrome.debugger.onEvent.addListener(this.onDebuggerEvent)
    chrome.debugger.onDetach.addListener(this.onDebuggerDetach)
    chrome.tabs.onCreated.addListener(this.onTabCreated)
    chrome.tabs.onRemoved.addListener(this.onTabRemoved)
    chrome.downloads.onCreated.addListener(this.onDownloadCreated)
    chrome.downloads.onChanged.addListener(this.onDownloadChanged)
    socket.onmessage = (event) => this.receive(event.data)
    socket.onclose = () => this.close()
    socket.onerror = () => this.close()
    this.keepalive = setInterval(
      () => this.send({ method: "Codevisor.keepalive", params: {} }),
      20_000
    )
  }

  async receive(data) {
    let message
    try {
      message = JSON.parse(data)
      const result = await this.command(message)
      this.send({ id: message.id, result: result ?? {} })
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error)
      lastCommandError = errorMessage
      lastCommandErrorAt = Date.now()
      this.send({
        id: typeof message?.id === "number" ? message.id : -1,
        error: { message: errorMessage }
      })
    }
  }

  async command(message) {
    if (message.method?.startsWith("Codevisor.clipboard.")) {
      return runClipboardCommand(
        message.method.slice("Codevisor.clipboard.".length),
        message.params ?? {}
      )
    }
    if (message.method === "Codevisor.armDownload") {
      const sessionId = message.sessionId
      const tabId = this.sessionToTab.get(sessionId) ?? this.childSessionToTab.get(sessionId)
      if (tabId === undefined) throw new Error("Unknown Codevisor tab session")
      const tab = await chrome.tabs.get(tabId)
      this.pendingDownloads = this.pendingDownloads.filter(
        (pending) => pending.expiresAt > Date.now()
      )
      this.pendingDownloads.push({
        sessionId,
        tabId,
        pageUrl: tabUrl(tab),
        expiresAt: Date.now() + Math.max(1_000, Number(message.params?.timeoutMs ?? 30_000))
      })
      return {}
    }
    if (typeof message.sessionId === "string") {
      const tabId =
        this.sessionToTab.get(message.sessionId) ?? this.childSessionToTab.get(message.sessionId)
      if (tabId === undefined) throw new Error("Unknown Codevisor tab session")
      return chrome.debugger.sendCommand(
        this.sessionToTab.has(message.sessionId)
          ? { tabId }
          : { tabId, sessionId: message.sessionId },
        message.method,
        message.params ?? {}
      )
    }
    switch (message.method) {
      case "Target.setDiscoverTargets":
        return {}
      case "Target.getTargets": {
        const tabs = (await chrome.tabs.query({})).filter(
          (tab) =>
            Number.isInteger(tab.id) &&
            (/^(https?|file):/.test(tabUrl(tab)) || tabUrl(tab) === "about:blank")
        )
        for (const tab of tabs) this.allowedTabs.add(tab.id)
        return { targetInfos: tabs.map(tabTarget) }
      }
      case "Target.createTarget": {
        const tab = await chrome.tabs.create({
          url: message.params?.url ?? "about:blank",
          active: true
        })
        this.allowedTabs.add(tab.id)
        return { targetId: String(tab.id) }
      }
      case "Target.closeTarget": {
        const tabId = Number(message.params?.targetId)
        if (!this.allowedTabs.has(tabId)) throw new Error("That tab is not shared with Codevisor")
        await chrome.tabs.remove(tabId)
        return { success: true }
      }
      case "Target.attachToTarget": {
        const tabId = Number(message.params?.targetId)
        if (!this.allowedTabs.has(tabId)) throw new Error("That tab is not shared with Codevisor")
        const existing = this.tabToSession.get(tabId)
        if (existing !== undefined) return { sessionId: existing }
        await chrome.debugger.attach({ tabId }, "1.3")
        const sessionId = `tab:${tabId}`
        this.tabToSession.set(tabId, sessionId)
        this.sessionToTab.set(sessionId, tabId)
        return { sessionId }
      }
      case "Target.detachFromTarget": {
        const sessionId = message.params?.sessionId
        const tabId = this.sessionToTab.get(sessionId)
        if (tabId === undefined) return {}
        await chrome.debugger.detach({ tabId }).catch(() => {})
        this.sessionToTab.delete(sessionId)
        this.tabToSession.delete(tabId)
        for (const [childSessionId, ownerTabId] of this.childSessionToTab) {
          if (ownerTabId === tabId) this.childSessionToTab.delete(childSessionId)
        }
        return {}
      }
      case "Codevisor.getHistory":
        return {
          entries: await chrome.history.search({
            text: message.params?.text ?? "",
            ...(typeof message.params?.startTime === "number"
              ? { startTime: message.params.startTime }
              : {}),
            ...(typeof message.params?.endTime === "number"
              ? { endTime: message.params.endTime }
              : {}),
            maxResults:
              typeof message.params?.maxResults === "number"
                ? Math.max(1, Math.min(1000, message.params.maxResults))
                : 100
          })
        }
      default:
        throw new Error(`Unsupported browser command: ${message.method}`)
    }
  }

  async handleDownloadCreated(item) {
    this.pendingDownloads = this.pendingDownloads.filter(
      (pending) => pending.expiresAt > Date.now()
    )
    if (this.pendingDownloads.length === 0) return
    let index = this.pendingDownloads.findIndex(
      (pending) =>
        typeof item.referrer === "string" &&
        item.referrer.length > 0 &&
        item.referrer === pending.pageUrl
    )
    if (index < 0) index = 0
    const [pending] = this.pendingDownloads.splice(index, 1)
    if (pending === undefined) return
    this.downloadSessions.set(item.id, pending.sessionId)
    this.send({
      method: "Browser.downloadWillBegin",
      sessionId: pending.sessionId,
      params: {
        guid: String(item.id),
        url: item.finalUrl || item.url || "",
        suggestedFilename: fileName(item.filename),
        filePath: item.filename
      }
    })
    if (item.state === "complete" || item.state === "interrupted") {
      this.sendDownloadProgress(item.id, item.state, item.filename)
    }
  }

  async handleDownloadChanged(delta) {
    if (!this.downloadSessions.has(delta.id)) return
    const [item] = await chrome.downloads.search({ id: delta.id })
    const state = delta.state?.current ?? item?.state
    if (state === undefined) return
    this.sendDownloadProgress(delta.id, state, delta.filename?.current ?? item?.filename)
  }

  sendDownloadProgress(id, state, path) {
    const sessionId = this.downloadSessions.get(id)
    if (sessionId === undefined) return
    const normalized =
      state === "complete" ? "completed" : state === "interrupted" ? "canceled" : "inProgress"
    this.send({
      method: "Browser.downloadProgress",
      sessionId,
      params: {
        guid: String(id),
        state: normalized,
        ...(typeof path === "string" && path.length > 0 ? { filePath: path } : {})
      }
    })
    if (normalized === "completed" || normalized === "canceled") {
      this.downloadSessions.delete(id)
    }
  }

  send(message) {
    if (this.socket.readyState === WebSocket.OPEN) this.socket.send(JSON.stringify(message))
  }

  close() {
    if (this.closed) return
    this.closed = true
    clearInterval(this.keepalive)
    chrome.debugger.onEvent.removeListener(this.onDebuggerEvent)
    chrome.debugger.onDetach.removeListener(this.onDebuggerDetach)
    chrome.tabs.onCreated.removeListener(this.onTabCreated)
    chrome.tabs.onRemoved.removeListener(this.onTabRemoved)
    chrome.downloads.onCreated.removeListener(this.onDownloadCreated)
    chrome.downloads.onChanged.removeListener(this.onDownloadChanged)
    this.pendingDownloads = []
    this.downloadSessions.clear()
    for (const tabId of this.tabToSession.keys()) chrome.debugger.detach({ tabId }).catch(() => {})
    connections.delete(this)
  }
}

const shareableTabIds = async () =>
  (await chrome.tabs.query({}))
    .filter(
      (tab) =>
        Number.isInteger(tab.id) &&
        typeof tab.url === "string" &&
        (/^(https?|file):/.test(tab.url) || tab.url === "about:blank")
    )
    .map((tab) => tab.id)

const clearReconnectSchedule = () => {
  reconnectScheduleGeneration += 1
  clearTimeout(reconnectTimer)
  reconnectTimer = undefined
  nextReconnectAt = undefined
  return chrome.alarms.clear(RECONNECT_ALARM).catch(() => false)
}

const connectionStatus = () => {
  const connected = connections.size > 0
  const activeConnections = [...connections]
  return {
    connected,
    state: connected ? "connected" : connectionState,
    availableTabs: activeConnections.reduce(
      (total, connection) => total + connection.allowedTabs.size,
      0
    ),
    controlledTabs: activeConnections.reduce(
      (total, connection) => total + connection.tabToSession.size,
      0
    ),
    reconnectAttempt,
    nextReconnectAt: nextReconnectAt ?? null,
    lastConnectedAt: lastConnectedAt ?? null,
    lastDisconnectedAt: lastDisconnectedAt ?? null,
    lastConnectionError: lastConnectionError ?? null,
    lastCommandError: lastCommandError ?? null,
    lastCommandErrorAt: lastCommandErrorAt ?? null,
    relay: CODEVISOR_RELAY,
    version: chrome.runtime.getManifest().version
  }
}

const reconnectDelay = () => {
  const exponential = Math.min(
    RECONNECT_MAX_DELAY_MS,
    RECONNECT_BASE_DELAY_MS * 2 ** Math.min(reconnectAttempt, 5)
  )
  const jitter = exponential * (Math.random() * 0.4 - 0.2)
  return Math.max(RECONNECT_BASE_DELAY_MS, Math.round(exponential + jitter))
}

const scheduleReconnect = () => {
  if (
    activeSocket?.readyState === WebSocket.CONNECTING ||
    activeSocket?.readyState === WebSocket.OPEN
  ) {
    return
  }
  const cleared = clearReconnectSchedule()
  const scheduleGeneration = reconnectScheduleGeneration
  const delay = reconnectDelay()
  reconnectAttempt += 1
  connectionState = "reconnecting"
  nextReconnectAt = Date.now() + delay
  const scheduledAt = nextReconnectAt
  reconnectTimer = setTimeout(connectToCodevisor, delay)
  void cleared.then(() => {
    if (scheduleGeneration === reconnectScheduleGeneration && nextReconnectAt === scheduledAt) {
      return chrome.alarms.create(RECONNECT_ALARM, { when: scheduledAt })
    }
  })
}

const connectToCodevisor = () => {
  if (
    activeSocket?.readyState === WebSocket.CONNECTING ||
    activeSocket?.readyState === WebSocket.OPEN
  ) {
    return
  }
  clearReconnectSchedule()
  connectionState = reconnectAttempt === 0 ? "connecting" : "reconnecting"
  let socket
  try {
    socket = new WebSocket(CODEVISOR_RELAY)
  } catch (error) {
    lastConnectionError = error instanceof Error ? error.message : String(error)
    lastDisconnectedAt = Date.now()
    activeSocket = undefined
    scheduleReconnect()
    return
  }
  activeSocket = socket
  let connection
  const connectionTimeout = setTimeout(() => {
    if (activeSocket !== socket || socket.readyState !== WebSocket.CONNECTING) return
    lastConnectionError = "Codevisor did not respond within 10 seconds"
    socket.close()
  }, CONNECT_TIMEOUT_MS)
  socket.addEventListener("open", async () => {
    clearTimeout(connectionTimeout)
    try {
      const initialTabIds = await shareableTabIds()
      if (activeSocket !== socket || socket.readyState !== WebSocket.OPEN) return
      connection = new CodevisorConnection(socket, initialTabIds)
      connections.add(connection)
      reconnectAttempt = 0
      connectionState = "connected"
      lastConnectedAt = Date.now()
      lastConnectionError = undefined
      clearReconnectSchedule()
    } catch (error) {
      lastConnectionError = error instanceof Error ? error.message : String(error)
      socket.close()
    }
  })
  socket.addEventListener("close", () => {
    clearTimeout(connectionTimeout)
    connection?.close()
    if (activeSocket !== socket) return
    activeSocket = undefined
    lastDisconnectedAt = Date.now()
    lastConnectionError ??= "The connection to Codevisor closed"
    scheduleReconnect()
  })
  socket.addEventListener("error", () => {
    if (activeSocket === socket) {
      lastConnectionError = "Could not connect to Codevisor"
    }
    socket.close()
  })
}

const reconnectNow = () => {
  clearReconnectSchedule()
  reconnectAttempt = 0
  connectionState = "connecting"
  lastConnectionError = undefined
  const socket = activeSocket
  activeSocket = undefined
  for (const connection of [...connections]) connection.close()
  if (socket && socket.readyState !== WebSocket.CLOSED) socket.close()
  connectToCodevisor()
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "status") {
    sendResponse(connectionStatus())
    return false
  }
  if (message?.type === "reconnect") {
    reconnectNow()
    sendResponse(connectionStatus())
    return false
  }
  return false
})

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === RECONNECT_ALARM) connectToCodevisor()
})

self.addEventListener("online", () => {
  if (connections.size === 0) reconnectNow()
})

connectToCodevisor()
