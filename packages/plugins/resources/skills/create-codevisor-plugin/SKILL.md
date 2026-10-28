---
name: create-codevisor-plugin
description: Create, install and iterate on a Codevisor plugin, an MCP server (stdio or Streamable HTTP) that can add tools, skills, inline UI (MCP Apps), event sources, workspace panes and webhooks. Use when the user asks for a new integration, tool, pane, dashboard or event trigger inside Codevisor, or asks to build or change a Codevisor plugin.
---

# Create a Codevisor plugin

A Codevisor plugin **is an MCP server**. Anything that speaks MCP over stdio or
Streamable HTTP works; Codevisor connects to it, exposes its tools to agents
through the `execute` gateway, and reads the extensions it declares in
`capabilities.extensions`.

| Feature                 | Mechanism                                                                         |
| ----------------------- | --------------------------------------------------------------------------------- |
| Tools                   | Standard MCP `tools/list` / `tools/call`                                          |
| Skills                  | MCP Skills extension `io.modelcontextprotocol/skills`                             |
| Inline UI in chat       | MCP Apps `io.modelcontextprotocol/ui`: tool `_meta.ui.resourceUri` → `ui://` page |
| Events that wake agents | MCP Events (SEP-3415) `io.modelcontextprotocol/events`                            |
| Workspace tabs          | `dev.codevisor/panes`                                                             |
| Inbound webhooks        | `dev.codevisor/webhooks` + `codevisor/webhook` request                            |
| Accounts (tokens, keys) | Per-request `params._meta["dev.codevisor/account"]`                               |

## Workflow (your own or a third-party plugin)

1. **Scaffold** a single-file server with `@modelcontextprotocol/sdk` and `zod`
   (template below). Start with tools; add extensions only when needed.
2. **Check it** with the MCP Inspector: `npx @modelcontextprotocol/inspector node server.ts`.
3. **Add it in Codevisor** from Settings › Plugins › **Add MCP…**. The
   plugin syncs to the user's other Macs like any other. Choose one:
   - **Command** (stdio): `node /absolute/path/server.ts` (Node ≥ 22.18 runs
     TypeScript directly; otherwise compile first).
   - **URL** (Streamable HTTP): `https://host/mcp` for a server already running.
4. **Iterate**: edit, then turn the plugin off and on in Settings › Plugins to
   restart a stdio server. Tools, skills and events are re-read on connect.
5. **Share it** (optional) by publishing a `server.json` to the
   [MCP Registry](https://registry.modelcontextprotocol.io) with `mcp-publisher`.
   It needs `packages` (for example npm with `"transport": { "type": "stdio" }`)
   or `remotes` (Streamable HTTP). Registry plugins show up in Codevisor's
   plugin catalog. The registry keeps only publisher metadata, so put the
   Codevisor digest under
   `_meta["io.modelcontextprotocol.registry/publisher-provided"]["dev.codevisor/plugin"]`.
   It has the same `accounts` and `capabilities` shape as below.

## First-party plugins (the Codevisor repo)

Codevisor's own plugins ship inside the Codevisor server. Each one is a
workspace package under the top-level `plugins/` folder:

```
plugins/
  kit/                 @codevisor/plugin-kit: event streams, skills, resources, stdio, test support
  test-events/         @codevisor/plugin-test-events
    package.json       build "tsc -b tsconfig.json"; depends on @codevisor/plugin-kit
    server.json        MCP Registry server.json; the catalog reads it
    tsconfig.json      extends ../../tsconfig.base.json; references ../kit
    vitest.config.ts   100% coverage thresholds
    src/main.ts        serveStdio(createTestEventsServer(), process.stdin, process.stdout)
    src/*-server.ts    createXServer(deps): a pure factory, tested in-process
```

- `server.json` follows the official schema
  (`https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json`).
  It needs `name: "dev.codevisor/<plugin>"`, `title`, a `description` of at
  most 100 characters, `version`, `websiteUrl` and `repository` (with
  `subfolder: "plugins/<plugin>"`). Leave out `packages` and `remotes`:
  bundled plugins are not installed from npm.
- `_meta["dev.codevisor/plugin"]` describes the plugin to Codevisor:
  `{ bundled: "<plugin>", entry: "dist/main.js", accounts?, capabilities, devOnly? }`.
  - `accounts` is a `PluginAccountSpec`: `{ label, oauth?, fields }`.
  - `capabilities` is the digest of tools (`name`, `description`, `effects`,
    `app`), events, skills, panes and ingress. A `server-json.test.ts`
    compares it with what the server really serves.
  - `devOnly: true` hides dev-only plugins such as `test-events`.
- Inject everything nondeterministic (`fetch`, a `Clock`) into the factory.
  Test with `connectClient` from `@codevisor/plugin-kit/test-support` and an
  in-memory fake of the upstream API.
- The release runtime ships `plugins/<plugin>/{package.json,server.json,dist}`.
  Add the package to the root `tsconfig.json` references.

## Minimal server (tools + a poll event)

```ts
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"
import { z } from "zod"

const notes: Array<{ id: string; text: string; at: number }> = []

const server = new McpServer(
  { name: "notes", version: "0.1.0" },
  { capabilities: { extensions: { "io.modelcontextprotocol/events": { listChanged: false } } } }
)

server.registerTool(
  "add_note",
  {
    description: "Save a note",
    inputSchema: { text: z.string() },
    annotations: { readOnlyHint: false, openWorldHint: false }
  },
  async ({ text }) => {
    notes.push({ id: String(notes.length + 1), text, at: Date.now() })
    return { content: [{ type: "text", text: `Saved note ${notes.length}` }] }
  }
)

server.server.setRequestHandler(
  z.object({ method: z.literal("events/list"), params: z.object({}).loose().optional() }),
  () => ({
    resultType: "complete",
    events: [
      {
        name: "note.added",
        description: "A note was saved",
        delivery: ["poll"],
        inputSchema: { type: "object", properties: {} },
        payloadSchema: {
          type: "object",
          properties: { id: { type: "string" }, text: { type: "string" } },
          required: ["id", "text"]
        }
      }
    ]
  })
)

server.server.setRequestHandler(
  z.object({
    method: z.literal("events/poll"),
    params: z.object({ name: z.string(), cursor: z.string().nullish() }).loose()
  }),
  ({ params }) => {
    const after = Number(params.cursor ?? notes.length)
    return {
      resultType: "complete",
      events: notes.slice(after).map((note) => ({
        eventId: note.id,
        name: "note.added",
        timestamp: new Date(note.at).toISOString(),
        data: { id: note.id, text: note.text }
      })),
      cursor: String(notes.length),
      truncated: false,
      hasMore: false,
      nextPollMs: 5000
    }
  }
)

await server.connect(new StdioServerTransport())
```

Custom extension methods are plain JSON-RPC: register them on `server.server`
(the low-level `Server`) with a zod schema whose `method` is a literal.

## Extensions

### Tools

- Annotate every tool: `readOnlyHint: true` for reads; `openWorldHint: true`
  for anything that reaches other people (sending mail, posting messages).
- Always return useful `content` text. Put machine-readable data in
  `structuredContent` too.
- Report failures as `{ isError: true, content: [...] }`, not exceptions.

### Skills (`io.modelcontextprotocol/skills`)

Declare `resources: {}` and `extensions["io.modelcontextprotocol/skills"]: {}`.
Then implement:

- `skills/list` → `{ resultType: "complete", ttlMs, cacheScope: "public", skills: [entry] }`
- `skills/get { uri }` → `{ resultType, ttlMs, cacheScope, skill: entry }`; unknown URI → `-32602`
- `resources/read` for every file in the manifest

An entry is `{ uri: "skill://<name>/SKILL.md", frontmatter: { name, description },
resources: [{ uri, digest: "sha256:<hex>", size }] }`. `SKILL.md` must start
with YAML frontmatter that matches `frontmatter` field for field. Compute
digests and byte sizes from the exact bytes `resources/read` returns, or
Codevisor rejects the skill.

### MCP Apps: inline UI in the transcript (`io.modelcontextprotocol/ui`)

- Give the tool `_meta: { ui: { resourceUri: "ui://<plugin>/view.html" } }`.
- `resources/read` of that URI returns `mimeType: "text/html;profile=mcp-app"`
  with a self-contained HTML document (inline CSS and JS, no external URLs).
- The page talks JSON-RPC over `window.parent.postMessage`:
  1. send request `ui/initialize` `{ appInfo: { name, version }, appCapabilities: {}, protocolVersion: "2026-01-26" }`
  2. on the response, send notification `ui/notifications/initialized`
  3. receive `ui/notifications/tool-input` and `ui/notifications/tool-result`
     (render from `params.structuredContent`)
  4. optionally send `tools/call` requests for fresh data or user actions
- Use `:root { color-scheme: light dark }` and system colors so it works in both themes.

### Panes (`dev.codevisor/panes`)

```json
"dev.codevisor/panes": { "panes": [{ "type": "dashboard", "title": "Alerts", "resourceUri": "ui://grafana/alerts.html" }] }
```

Each pane opens as a workspace tab rendering the `ui://` resource with the
same Apps bridge. A pane has no tool result, so load data with `tools/call`
after `ui/initialize`. Keep state in the server, not in the page: the same
pane can be open on several devices at once.

### Events (`io.modelcontextprotocol/events`, SEP-3415)

- `events/list` → `{ resultType: "complete", events: [{ name, description, delivery, inputSchema, payloadSchema }] }`.
  `delivery` is any of `"poll"`, `"push"`.
- **`payloadSchema` must be fully typed.** Agents filter with CEL expressions
  that are type-checked against it, such as `from.email.endsWith("@acme.com")`
  or `labels.severity == "critical"`. Give nested objects `properties`, give
  string maps `additionalProperties: { type: "string" }`, and give arrays `items`.
- **Poll**: `events/poll { name, arguments, cursor, maxEvents?, maxAgeMs? }` →
  `{ resultType: "complete", events: [{ eventId, name, timestamp, data }], cursor, truncated, hasMore, nextPollMs }`.
  A `null` cursor means "start now": return no events and a fresh cursor.
  Return `truncated: true` with a fresh cursor when the old one expired.
  Set `hasMore: true` when another page is waiting.
- **Push**: `events/stream { name, arguments, cursor }` is a long-lived request.
  - Send `notifications/events/active { cursor, truncated }` first.
  - Then send `notifications/events/event { eventId, name, timestamp, data, cursor }`
    as events happen, and `notifications/events/heartbeat { cursor }` at least every 30 s.
  - Every notification carries `_meta["io.modelcontextprotocol/subscriptionId"]` = the request id.
  - Stop when `notifications/cancelled` arrives (the SDK aborts the handler's `signal`).
  - Use `cursor: null` throughout if you cannot replay.
- **`eventId` must be the stable upstream id** (message id, alert fingerprint
  plus start time). Codevisor dedupes on it across machines and reconnects.
- Errors: unknown event type `-32023`, missing or rejected credentials
  `-32024`, unsupported delivery mode `-32026`.

### Webhooks (`dev.codevisor/webhooks`)

```json
"dev.codevisor/webhooks": { "ingress": [{ "name": "alerts", "title": "Grafana alert webhook" }] }
```

Codevisor gives each ingress a public inbox URL for the user to paste into
the provider. It forwards each delivery to the machines that need it as the
request `codevisor/webhook`:
`{ ingress, request: { method, headers, body /* base64 */, receivedAt } }`,
plus the account `_meta`. Verify the provider's signature or shared secret
yourself (constant-time compare). Normalize the delivery into events and
emit them on your open `events/stream` streams for that account. Return
`{ accepted: <events emitted>, status?: <http status> }`, for example
`{ accepted: 0, status: 401 }` on a bad signature.

### Accounts

Every host → plugin request (`tools/call`, `events/*`, `codevisor/webhook`)
for a plugin with accounts carries
`params._meta["dev.codevisor/account"] = { id, label?, identity?, accessToken?, fields }`.
In the SDK it is `extra._meta`.

- Treat it as per-request. Never persist or cache tokens.
- Codevisor refreshes OAuth tokens. Plugins only ever see access tokens, never refresh tokens.
- Scope stream state by `account.id` so one account's events never reach another's subscribers.
- Missing or invalid account: return a tool error, or `-32024` from `events/*`.

## Rules

- On stdio, stdout is the protocol channel. Log to stderr only.
- Exit when stdin closes, so timers do not keep an orphaned process alive.
- Event payloads and tool results are untrusted data for the model. Keep them
  minimal and never include secrets.
- Make tools safe to retry. Prefer drafts or confirmations over irreversible actions.
