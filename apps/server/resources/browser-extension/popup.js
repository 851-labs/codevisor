const elements = {
  summary: document.querySelector("#connection-summary"),
  statusDot: document.querySelector("#status-dot"),
  controlledTabs: document.querySelector("#controlled-tabs"),
  reconnect: document.querySelector("#reconnect"),
  connectionState: document.querySelector("#connection-state"),
  availableTabs: document.querySelector("#available-tabs"),
  lastConnected: document.querySelector("#last-connected"),
  relay: document.querySelector("#relay"),
  version: document.querySelector("#version"),
  errorRow: document.querySelector("#error-row"),
  lastError: document.querySelector("#last-error"),
  copyDiagnostics: document.querySelector("#copy-diagnostics"),
  copyResult: document.querySelector("#copy-result")
}

let currentStatus
let refreshTimer

const titleCase = (value) =>
  String(value || "disconnected").replace(/^./, (character) => character.toUpperCase())

const formattedTime = (timestamp) => {
  if (typeof timestamp !== "number") return "Never"
  return new Date(timestamp).toLocaleTimeString([], {
    hour: "numeric",
    minute: "2-digit",
    second: "2-digit"
  })
}

const summaryFor = (status) => {
  if (status.connected) return "Connected to Codevisor"
  if (status.state === "connecting") return "Connecting to Codevisor…"
  if (status.state === "reconnecting" && typeof status.nextReconnectAt === "number") {
    const seconds = Math.max(1, Math.ceil((status.nextReconnectAt - Date.now()) / 1_000))
    return `Reconnecting in ${seconds}s…`
  }
  return "Codevisor is unavailable"
}

const render = (status) => {
  currentStatus = status
  const state = status.connected ? "connected" : status.state || "disconnected"
  elements.summary.textContent = summaryFor(status)
  elements.statusDot.className = `status-dot ${state}`
  elements.controlledTabs.textContent = String(status.controlledTabs ?? 0)
  elements.reconnect.hidden = status.connected
  elements.connectionState.textContent = titleCase(state)
  elements.availableTabs.textContent = String(status.availableTabs ?? 0)
  elements.lastConnected.textContent = formattedTime(status.lastConnectedAt)
  elements.relay.textContent = status.relay || "Unavailable"
  elements.relay.title = status.relay || ""
  elements.version.textContent = status.version || "Unknown"
  const error = status.lastConnectionError || status.lastCommandError
  elements.errorRow.hidden = !error
  elements.lastError.textContent = error || "—"
  elements.lastError.title = error || ""
}

const disconnectedStatus = (error) => ({
  connected: false,
  state: "disconnected",
  controlledTabs: 0,
  availableTabs: 0,
  lastConnectionError: error instanceof Error ? error.message : String(error)
})

const refresh = async () => {
  try {
    render(await chrome.runtime.sendMessage({ type: "status" }))
  } catch (error) {
    render(disconnectedStatus(error))
  }
}

elements.reconnect.addEventListener("click", async () => {
  elements.reconnect.disabled = true
  elements.reconnect.textContent = "Connecting…"
  try {
    render(await chrome.runtime.sendMessage({ type: "reconnect" }))
  } catch (error) {
    render(disconnectedStatus(error))
  } finally {
    elements.reconnect.disabled = false
    elements.reconnect.textContent = "Reconnect"
  }
})

elements.copyDiagnostics.addEventListener("click", async () => {
  if (!currentStatus) return
  try {
    await navigator.clipboard.writeText(JSON.stringify(currentStatus, null, 2))
    elements.copyResult.textContent = "Copied"
  } catch {
    elements.copyResult.textContent = "Couldn’t copy"
  }
  setTimeout(() => {
    elements.copyResult.textContent = ""
  }, 1_500)
})

void refresh()
refreshTimer = setInterval(refresh, 1_000)
window.addEventListener("unload", () => clearInterval(refreshTimer), { once: true })
