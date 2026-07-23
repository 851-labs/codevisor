importScripts("relay-config.js")

const connections = new Set()
const CODEVISOR_RELAY = globalThis.CODEVISOR_RELAY
let reconnectTimer
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
      this.send({
        id: typeof message?.id === "number" ? message.id : -1,
        error: { message: error instanceof Error ? error.message : String(error) }
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

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "status") return false
  sendResponse({ connected: connections.size > 0 })
  return false
})

chrome.action.onClicked.addListener(() => {
  chrome.tabs.create({ url: chrome.runtime.getURL("connect.html") })
})

const shareableTabIds = async () =>
  (await chrome.tabs.query({}))
    .filter(
      (tab) =>
        Number.isInteger(tab.id) &&
        typeof tab.url === "string" &&
        (/^(https?|file):/.test(tab.url) || tab.url === "about:blank")
    )
    .map((tab) => tab.id)

const connectToCodevisor = () => {
  clearTimeout(reconnectTimer)
  const socket = new WebSocket(CODEVISOR_RELAY)
  let connection
  socket.addEventListener("open", async () => {
    connection = new CodevisorConnection(socket, await shareableTabIds())
    connections.add(connection)
  })
  socket.addEventListener("close", () => {
    connection?.close()
    reconnectTimer = setTimeout(connectToCodevisor, 1_000)
  })
  socket.addEventListener("error", () => socket.close())
}

connectToCodevisor()
