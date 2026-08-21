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
   page). Pane records need `providerId: "plugin:<pluginId>"` and the pane
   `type`; do not persist icon metadata in the workspace record.
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
  "iconPath": "/assets/icon.svg",
  "panes": [{ "type": "main", "title": "My Plugin", "path": "/panes/main/" }],
  "run": { "command": "node server.js" },
  "healthPath": "/health"
}
```

- `id`: lowercase `owner.name` (letters/digits/hyphens, exactly one dot).
- Pane `path` MUST start **and** end with `/`.
- `install: {"command": "..."}` only if dependencies are unavoidable.
- `iconPath` is an optional plain absolute server path to SVG, PNG, or WebP.
  A pane-level `iconPath` overrides the plugin path; otherwise it inherits it.

Create the referenced `assets/icon.svg` as self-contained full-color artwork
(no scripts, embedded HTML, external links, or external CSS):

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="14" fill="#7657e8"/>
  <circle cx="32" cy="32" r="13" fill="#fff"/>
</svg>
```

## Server template (zero-dep Node)

```js
const http = require("http")
const { readFile } = require("node:fs/promises")
const path = require("node:path")

const decodeContext = (header) => {
  try {
    return JSON.parse(Buffer.from(header ?? "", "base64").toString("utf8"))
  } catch {
    return {}
  }
}

http
  .createServer(async (request, response) => {
    const url = new URL(request.url, "http://127.0.0.1")
    const context = decodeContext(request.headers["x-codevisor-context"])
    if (url.pathname === "/health") return response.end("ok")
    if (url.pathname === "/assets/icon.svg") {
      response.writeHead(200, { "Content-Type": "image/svg+xml" })
      return response.end(await readFile(path.join(__dirname, "assets/icon.svg")))
    }
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
- **Serve `iconPath` with the right MIME type.** Codevisor accepts SVG, PNG,
  and WebP up to 512 KiB, rejects active/external SVG content, and normalizes
  every asset to a 256 px PNG for clients. Use full-color artwork that works
  on light and dark backgrounds; it is not tinted like a system symbol.
- Read per-pane context (cwd, workspaceId, paneId, themeMode) from the
  `X-Codevisor-Context` header: base64 JSON, present on every proxied request.
- Style with the injected `--codevisor-*` CSS variables so panes match the
  app theme (full reference under "Styling panes"); every `var()` needs a
  fallback: `var(--codevisor-bg, Canvas)`.
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
- WebSockets work (relative URLs). Prefer fetch for bulk data and WS for
  "something changed" signals.

## Exposing tools to the model

Plugins can declare agent-invocable tools next to panes. Add to the manifest:

```json
"tools": [
  {
    "name": "notes_add",
    "description": "Append a note",
    "path": "/tools/add",
    "inputSchema": {
      "type": "object",
      "properties": { "text": { "type": "string" } },
      "required": ["text"]
    }
  },
  { "name": "notes_list", "description": "List saved notes", "path": "/tools/list" }
]
```

- `name`: lowercase letters/digits/underscores, unique within the plugin.
- `path`: plain absolute path; no trailing slash needed (RPC endpoint, not a
  document).
- `inputSchema`: optional JSON Schema for the arguments, shown to agents.

The contract: Codevisor POSTs the JSON arguments to `path` on your server,
with the same signed `X-Codevisor-Context` header (here carrying `pluginId`,
`toolName`, and the caller's `workspaceId`/`cwd` when known). Respond 2xx
with JSON (or plain text); any non-2xx marks the call failed. The installed
plugin process is already running; tool-only plugins are valid, so leave
`panes` empty. Agents discover and call the tool as
`plugin.<pluginId>.<toolName>` through the Codevisor tool gateway; clients
can also `POST /v1/plugins/<pluginId>/tools/<toolName>` with
`{ "args": { ... } }`.

```js
if (url.pathname === "/tools/add" && request.method === "POST") {
  let body = ""
  request.on("data", (chunk) => (body += chunk))
  request.on("end", () => {
    notes.push(JSON.parse(body || "{}").text)
    response.writeHead(200, { "Content-Type": "application/json" })
    response.end(JSON.stringify({ ok: true, count: notes.length }))
  })
  return
}
```

## Lifecycle facts (for debugging)

- Codevisor starts installed plugins after its main listener is ready and
  keeps them running until server shutdown. Crashes restart with backoff; 5
  consecutive failures → `failed` until `plugins.restart`.
- The server must accept connections on `$PORT` within 15s of spawn.
- Pane shows an error card? Check `plugins.list` state, then the output
  terminal. 502 = process unreachable (crashed?), 504 = request hung >30s.

## Styling panes

Panes render inside Codevisor's chrome, which is native macOS/iOS and
deliberately quiet: system font, small type (11–13px chrome, ~12px mono
content), hairline 1px borders, flat surfaces with at most one elevation
step, no shadows or gradients, whitespace over boxes, and color reserved
for meaning — the accent, status, and diff tokens below. A pane inherits
that look by building from these variables instead of its own palette.

The clients inject these on `:root` (values track the user's theme live —
a `codevisor:themechange` event fires on `window` when they change):

| Variable                                     | Meaning                               |
| -------------------------------------------- | ------------------------------------- |
| `--codevisor-bg`                             | pane background                       |
| `--codevisor-bg-elevated`                    | raised surface (cards, header bars)   |
| `--codevisor-fg`                             | primary text                          |
| `--codevisor-fg-secondary`                   | secondary text                        |
| `--codevisor-fg-tertiary`                    | faint text (placeholders, timestamps) |
| `--codevisor-border`                         | control borders                       |
| `--codevisor-separator`                      | hairline dividers                     |
| `--codevisor-accent`                         | interactive/highlight color           |
| `--codevisor-status-ok` / `-warn` / `-error` | status colors                         |
| `--codevisor-diff-added` / `-removed`        | diff foregrounds                      |
| `--codevisor-diff-added-bg` / `-removed-bg`  | diff line backgrounds                 |
| `--codevisor-font-family`                    | UI font (system stack)                |
| `--codevisor-font-family-mono`               | monospace font                        |

Because the variables only exist inside the app's webviews (see "Seeing
your pane"), every `var()` carries a fallback; `color-mix` against
`Canvas`/`CanvasText` plus `:root { color-scheme: light dark }` keeps the
fallbacks theme-correct too — the git-diff reference plugin
(codevisor repo, `plugins/git-diff/server.ts`) shows the full pattern.

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

To list it in the plugin registry (Settings ▸ Plugins ▸ Browse and
codevisor.dev/plugins), add the `codevisor-plugin` GitHub topic to the
repo; the registry indexes it within ~15 minutes. The manifest must sit at
the repo root and its id namespace must equal the repo owner, or the entry
is rejected (rejections and reasons appear in the index's `rejected` list).
Untag the repo to delist it.
