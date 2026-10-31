import { mcpAppMimeType, type ServedResource } from "@codevisor/plugin-kit"

import { eventsPageUri } from "./test-events-catalog.js"

export const eventsPageScript = `
const list = document.getElementById("events")
const status = document.getElementById("status")
const pending = new Map()
let nextId = 1

const post = (message) => window.parent.postMessage({ jsonrpc: "2.0", ...message }, "*")

const request = (method, params) =>
  new Promise((resolve, reject) => {
    const id = nextId++
    pending.set(id, { resolve, reject })
    post({ id, method, params })
  })

const row = (event) => {
  const item = document.createElement("li")
  item.textContent = event.timestamp + "  " + event.name + "  " + JSON.stringify(event.data)
  return item
}

const render = (result) => {
  const events = result?.structuredContent?.events ?? []
  list.replaceChildren(...events.map(row))
  status.textContent = events.length + " recent events"
}

const settle = (message) => {
  const waiter = pending.get(message.id)
  pending.delete(message.id)
  if (message.error) waiter.reject(new Error(message.error.message))
  else waiter.resolve(message.result)
}

window.addEventListener("message", (event) => {
  const message = event.data
  if (message?.jsonrpc !== "2.0") return
  if (pending.has(message.id)) settle(message)
  else if (message.method === "ui/notifications/tool-result") render(message.params)
})

const start = async () => {
  await request("ui/initialize", {
    appInfo: { name: "test-events", version: "1.0.0" },
    appCapabilities: {},
    protocolVersion: "2026-01-26"
  })
  post({ method: "ui/notifications/initialized", params: {} })
  render(await request("tools/call", { name: "list_recent", arguments: {} }))
}

start().catch((error) => {
  status.textContent = error.message
})
`

const eventsPageHtml = `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Test events</title>
<style>
:root { color-scheme: light dark; font-family: var(--font-sans, system-ui, sans-serif); }
body { margin: 0; padding: 12px; background: var(--color-background-primary, transparent); color: var(--color-text-primary, CanvasText); }
h1 { font-size: 14px; margin: 0 0 4px; }
p { margin: 0 0 8px; font-size: 12px; opacity: 0.7; }
ul { list-style: none; margin: 0; padding: 0; font-family: var(--font-mono, ui-monospace, monospace); font-size: 12px; }
li { padding: 4px 0; border-top: 1px solid color-mix(in srgb, currentColor 12%, transparent); overflow-wrap: anywhere; }
</style>
</head>
<body>
<h1>Test events</h1>
<p id="status">Connecting…</p>
<ul id="events"></ul>
<script>${eventsPageScript}</script>
</body>
</html>
`

export const eventsPage: ServedResource = {
  uri: eventsPageUri,
  name: "Test events",
  mimeType: mcpAppMimeType,
  text: eventsPageHtml
}
