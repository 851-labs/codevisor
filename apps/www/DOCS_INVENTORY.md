# Codevisor documentation inventory

Last audited: 2026-08-20

This source-of-truth map compares the rendered content in `content/docs` with
the product and server implementation. It stays outside `content/docs` so
planning notes are not published.

## Product coverage

| Surface                                                       | Current public coverage                    | Implementation evidence                                    |
| ------------------------------------------------------------- | ------------------------------------------ | ---------------------------------------------------------- |
| Product model, installation, and first run                    | Get-started, install, and quickstart       | `apps/www/public/install.sh`, server CLI                   |
| Server configuration, auth, security, realtime, and terminals | Verified guides and generated API          | `apps/server/src`, `packages/api/src`                      |
| Projects, worktrees, workspaces, sessions, files, and events  | Concepts and generated API                 | Server route modules and API schemas                       |
| Harnesses and accounts                                        | Generated API and custom-agent guide       | `packages/harness-manager`, harness routes                 |
| MCP servers                                                   | Managed/native guide and generated API     | `packages/mcp`, MCP routes                                 |
| Skills                                                        | Authoring/management guide and API         | `packages/skills`, skills routes                           |
| Plugins                                                       | Authoring/runtime/publishing guide and API | `packages/plugins`, plugin routes, public plugin directory |
| Browser and computer automation                               | MCP relationship and security boundary     | `packages/automation`, browser-use routes                  |

The documentation is intentionally organized around Codevisor Server and its extension contracts.
It does not maintain separate macOS or iOS product manuals.

## HTTP surface classification

The server exposes more routes than the generated OpenAPI document. Until a
formal stability policy exists, documentation uses these classifications:

### Documented client API — public, experimental

`packages/api/src/openapi.ts` is the allowlist for the generated reference. It
currently covers these route families:

- Server discovery, health, info, capabilities, updates, shutdown, and tailnet peers
- Pairing and connection tokens
- Projects, Git branches, worktrees, and filesystem listing
- Workspaces and panes
- Harness discovery, accounts, provider authentication, and agent-session discovery
- Custom ACP harness listing, testing, and replacement
- Plugin discovery, installation/linking, lifecycle, pane tokens, and tools
- Managed MCP servers, native MCP discovery/import/editing, and project/session scopes
- Skills creation, import, synchronization, promotion, installation, and removal
- Sessions, transcripts, prompts, queues, goals, approvals, events, and usage data
- File upload/download, global events, and terminals

These routes are suitable for third-party clients, but the docs must continue
to label the API experimental until versioning and compatibility guarantees are
defined.

### First-party client API — classification pending

These implemented routes are used by Codevisor or its automation tooling but
are absent from OpenAPI. A future contract review must either promote each
family with schemas and docs or explicitly mark it internal:

- `/v1/cloud*`
- `/v1/browser-use*` except transport-only routes listed below
- Harness installation, update, and bundled-app routes
- `/v1/fs/file`

### Internal transport — not a third-party client contract

- `/v1/mcps/oauth/callback` and `/v1/mcps/oauth/complete`
- `/v1/browser-use/extension/socket` and extension asset/install helper routes
- `ANY /v1/plugins/:pluginId/app/*`, including proxied WebSockets

These exist to complete browser, OAuth, and plugin-pane flows. They should be
explained where developers need the architecture, but not presented as general
client endpoints.

## Audit sources

- Published structure: `apps/www/content/docs`
- Generated reference allowlist: `packages/api/src/openapi.ts`
- Actual route dispatch: `apps/server/src/server.ts` and `apps/server/src/routes`
- Automation-facing API map: `packages/automation/src/codevisor-api-tools.ts`
- macOS product surface: `apps/macos/Codevisor/Features`
- iOS product surface: `apps/ios/Codevisor/Features`
- Plugin authoring source: `packages/plugins/resources/skills/create-codevisor-plugin/SKILL.md`

Update this inventory whenever a user-visible feature or server route family is
added, removed, or changes classification.
