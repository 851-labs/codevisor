---
name: create-codevisor-plugin
description: Create, install, and iterate on a Codevisor plugin — a local HTTP server whose panes render inside Codevisor on every connected device. Use when the user asks for a new pane, panel, viewer, dashboard, or tool inside Codevisor (e.g. "make me a pane that shows X"), or asks to build or modify a Codevisor plugin.
---

# Create a Codevisor plugin

A plugin is a folder with a manifest and any program that serves HTTP on
`$PORT` (loopback). Codevisor supervises the process, proxies pane traffic to
it, and renders its pages in webview panes on every client (macOS, iOS,
remote). You can scaffold, install, and show a working pane in under a minute.

## Workflow

1. **Scaffold** a folder with `codevisor-plugin.json` + a single-file server
   (templates below). Prefer zero dependencies.
2. **Install it (dev mode)** so Codevisor discovers it:
   - Tool: `plugins.link` with the folder's absolute path, or
   - CLI: `codevisor plugin link <absolute-path>`
3. **Open a pane** so the user sees it immediately: use the
   `workspaces.open_plugin_pane` tool (or tell the user it's on the New Tab
   page). Pane records need `providerId: "plugin:<pluginId>"`, the pane
   `type`, and metadata JSON exactly like
   `{"icon":"<sf-symbol>","paneType":"<type>","pluginId":"<id>"}`
   (sorted keys; omit `icon` when the manifest has none).
4. **Iterate**: edit files → `plugins.restart` → open panes reload
   automatically on every connected device. HMR-capable dev servers (Vite
   etc.) also work without restarting, since WebSockets are proxied. Read
   runtime logs via the plugin's output terminal (Settings → Plugins → Show
   Output) when something fails.

## Manifest — `codevisor-plugin.json`

```json
{
  "protocolVersion": 1,
  "id": "<owner>.<name>",
  "name": "My Plugin",
  "description": "One line about what it does",
  "version": "0.1.0",
  "panes": [{ "type": "main", "title": "My Plugin", "path": "/panes/main/", "icon": "sparkles" }],
  "run": { "command": "node server.js" },
  "idleTimeoutSeconds": 300,
  "healthPath": "/health"
}
```

- `id`: lowercase `owner.name` (letters/digits/hyphens, exactly one dot).
- Pane `path` MUST start **and** end with `/`.
- `install: {"command": "..."}` only if dependencies are unavoidable.
- `icon` is an SF Symbol name (optional).

## Server template (zero-dep Node)

```js
const http = require("http")

const decodeContext = (header) => {
  try {
    return JSON.parse(Buffer.from(header ?? "", "base64").toString("utf8"))
  } catch {
    return {}
  }
}

http
  .createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1")
    const context = decodeContext(request.headers["x-codevisor-context"])
    if (url.pathname === "/health") return response.end("ok")
    if (url.pathname === "/panes/main/") {
      response.writeHead(200, { "Content-Type": "text/html; charset=utf-8" })
      return response.end(`<!doctype html><html><head><meta charset="utf-8">
      <style>body{margin:0;font-family:var(--codevisor-font-family,sans-serif);
      background:var(--codevisor-bg,Canvas);color:var(--codevisor-fg,CanvasText)}</style>
      </head><body><h1>Hello from ${context.cwd ?? "?"}</h1>
      <script>fetch("api/data").then(r => r.json()).then(console.log)</script>
      </body></html>`)
    }
    if (url.pathname === "/panes/main/api/data") {
      response.writeHead(200, { "Content-Type": "application/json" })
      return response.end(JSON.stringify({ cwd: context.cwd }))
    }
    response.writeHead(404).end()
  })
  .listen(Number(process.env.PORT), "127.0.0.1")
```

## Hard rules

- **Every URL in pane documents must be RELATIVE** (`api/data`, `./app.js` —
  never `/app.js` or absolute URLs). Panes are served under a proxy prefix;
  path-absolute URLs escape it and 404.
- **Bind `127.0.0.1` on `Number(process.env.PORT)`** — never `0.0.0.0`.
- Read per-pane context (cwd, workspaceId, paneId, themeMode) from the
  `X-Codevisor-Context` header: base64 JSON, present on every proxied request.
- Style with the injected CSS variables so panes match the app theme:
  `--codevisor-bg/-fg/-border/-accent/-font-family/-diff-added/-diff-removed`
  (and more — always provide fallbacks: `var(--codevisor-bg, Canvas)`).
- **Keep ALL state in your plugin server** — in memory for ephemera, under
  `$CODEVISOR_PLUGIN_DATA_DIR` for anything durable (never in the plugin
  folder). The same pane renders on multiple devices at once (Mac, iPhone,
  remote); server-side state means every device sees the same thing by
  construction, and reloads/reinstalls lose nothing. Scope per-pane state by
  the `paneId` (and per-project state by the `cwd`) from the request context.
- **Do not use localStorage/IndexedDB unless the user explicitly asks for
  device-local storage.** Browser storage is per-device (state saved on the
  Mac never appears on the phone), can silently reset on relayed
  connections, and is ONE shared bucket for the whole plugin — every pane in
  every workspace reads and writes the same keys, so two open panes will
  clobber each other's "per-pane" state. Your plugin IS a server:
  `fetch("api/state")` costs the same to write and is correct everywhere.
- The in-page bridge: `window.codevisor.getContext()`, `.openUrl(url)`,
  `.setTitle(title)`; theme changes fire a `codevisor:themechange` event
  (feature-detect it — the bridge only exists inside the app's webviews).
- WebSockets work (relative URLs). Prefer fetch for bulk data, WS for
  "something changed" signals. An open WS keeps the process alive.

## Lifecycle facts (for debugging)

- Processes start lazily on first pane request and idle-stop after
  `idleTimeoutSeconds` (default 300; `0` = never). Crashes restart with
  backoff; 5 consecutive failures → `failed` until `plugins.restart`.
- The server must accept connections on `$PORT` within 15s of spawn.
- Pane shows an error card? Check `plugins.list` state, then the output
  terminal. 502 = process unreachable (crashed?), 504 = request hung >30s.

## Seeing your pane

`plugins.open_pane_url` returns a URL you can open with the browser tools:
it renders the same pane the user sees — an independent view backed by the
same plugin server, so state and interactions are shared both ways. Good
for screenshotting a pane after a change or driving its UI end to end.

A pane opened this way runs without the native clients' injections — no
`window.codevisor` bridge, no `--codevisor-*` CSS variables (those come
from the app's webview, not the proxy). This is why every `var()` carries
a fallback and why bridge use is feature-detected (`if (window.codevisor)`):
a pane written that way renders correctly anywhere it can be opened.

## Publishing (when the user asks)

Push the folder to a public GitHub repo whose owner matches the id's
namespace (`owner.name` ⇒ `github.com/owner/...`). Others install it with
`plugins.discover_remote` → user consent → `plugins.install`, or
`codevisor plugin install owner/repo`.
