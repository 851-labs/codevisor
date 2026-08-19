# Plugin marketplace — phased plan

Context: the full plugin system is on main (runtime, panes, tools, install
pipeline with consent, CLI, Settings UI, agent tools, authoring skill).
Missing: discovery. Design settled in prior discussion: GitHub-topic registry
(herdr model), Cloudflare-hosted index, clients only talk to their machine.

## Phase 1 — Indexer (Cloudflare, no client changes)

Scheduled Worker (in apps/cloud alongside the existing Hono worker, or a new
small apps/registry): every ~15 min, GitHub search API for public repos tagged
`codevisor-plugin` (authed token secret, paginated) → fetch each repo's
codevisor-plugin.json via raw content API → validate (manifest schema +
anti-impersonation: manifest id's `owner.` must equal the repo owner) → KV
index entries {id, name, description, version, panes, tools, repo, stars,
pushedAt} + rejected diagnostics. Serve GET /plugins/index.json (cache
headers) and GET /plugins/:id.json; POST /refresh for testing.
Verify: tag a test repo → appears; untag → drops.

## Phase 2 — Server passthrough

GET /v1/plugins/registry on the codevisor server: fetch + cache the index
(TTL ~10 min, stale-while-error). Clients/relay only talk to the machine.
Wire type + Swift mirror + `plugins.registry_search` agent tool entry.

## Phase 3 — In-app browse

"Browse" tab in Settings → Plugins (macOS + iOS): searchable registry list
(name, description, pane/tool counts, stars, owner) → detail → Install via
the EXISTING discover→consent→install flow (registry adds discovery, never
bypasses consent). Mark already-installed entries.

## Phase 4 — Public directory + publishing polish

codevisor.dev/plugins page in apps/www rendering the same index. Skill
Publishing section gains the topic-tagging step. Index schema gains a
`verified` flag (curation groundwork only). Install-count telemetry deferred.

## Risks

GitHub rate limits (authed token required); index poisoning (owner-match
validation + consent shows verbatim commands); name squatting (directory
shows real repo owner; defer).

## Repo facts for implementers

- Gates: 100% coverage packages/\*/src + apps/server/src (bun run check:js);
  full `bun run check` includes Swift + iOS lane; oxlint 500-line file cap;
  swiftlint baseline regeneration procedure in git history.
- Templates: apps/server/src/routes/plugins.ts (routes), packages/api/src/
  plugins.ts (Effect Schema wire types, Swift hand-mirrored in
  CodevisorServerClient+Plugins.swift), packages/automation/src/
  codevisor-api-tools.ts (agent tools), PluginsSettingsView.swift /
  PluginsSettingsScreen.swift (settings UI), apps/cloud (Hono worker,
  wrangler).
