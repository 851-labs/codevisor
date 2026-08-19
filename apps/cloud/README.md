# @codevisor/cloud

The Codevisor Cloud instance: sign in once, see all your machines, and connect
to them from anywhere through an **end-to-end encrypted relay** — no VPN, no
port forwarding.

One Cloudflare Worker contains the whole plane:

- **Auth** — [Better Auth](https://better-auth.com) on D1: GitHub OAuth for
  apps, RFC 8628 device flow for `codevisor auth login`, long-lived revocable
  api keys as machine credentials.
- **`UserHub` Durable Object** — one per account. Apps and machines dial in
  over WebSockets (hibernation: idle machines cost ~nothing); the hub tracks
  presence and routes relay frames between peers.
- **Relay protocol** — multiplexed channels (`@codevisor/api` cloud-protocol).
  Channel payloads are sealed end-to-end between devices
  (`@codevisor/cloud-crypto`: X25519 + XChaCha20-Poly1305); the hub only ever
  sees ciphertext and envelope addressing. Even `channelType` is encrypted.
- **Pages** — three tiny server-rendered pages (`/`, `/login`, `/device`,
  `/auth/handoff`); everything else is native-app UI.
- **Plugin registry** — a cron trigger (every 15 min, or `POST
/plugins/refresh`) searches GitHub for public repos tagged
  `codevisor-plugin`, validates each repo's `codevisor-plugin.json` (manifest
  schema + the id must be namespaced under the repo owner), and serves the
  KV-backed index at `GET /plugins/index.json` / `GET /plugins/:id.json`.
  Rejected repos are published with diagnostics so authors can fix them.

## Development

`bun run dev` at the repo root starts this Worker automatically (`wrangler
dev`, local D1 + DOs persisted under `tmp/wrangler`) with `DEV_AUTH=1`:

- No GitHub OAuth app needed — `POST /dev/login` (or the "Continue as Dev
  User" button) signs in a fixed local dev user.
- Migrations are applied on boot.
- The app receives `CODEVISOR_DEV_CLOUD_URL` / `CODEVISOR_DEV_CLOUD_TOKEN`.

Standalone: `bun run --cwd apps/cloud dev`, tests with
`bun run --cwd apps/cloud test` (they run in workerd via
`@cloudflare/vitest-pool-workers` — real D1, real Durable Objects).

## Machine login flow

1. `codevisor auth login [--server https://cloud.example.com]` requests a
   device code (`POST /api/auth/device/code`, client id `codevisor-machine`).
2. The user opens `/device`, signs in (GitHub), and approves the code.
3. The CLI polls `/api/auth/device/token` → short-lived session token.
4. The machine generates its X25519 device keypair and exchanges the session
   for a long-lived api key (`POST /api/auth/api-key/create`) carrying
   `{ deviceId, publicKey }` metadata (`@codevisor/cloud-client
provisionMachine`).
5. It connects to `GET /connect` with `x-api-key` and speaks the hub protocol.
   Revoking the machine in app settings deletes the api key and drops it from
   the hub.

Apps connect to the same `/connect` with a session bearer token (or `?token=`
for browser WebSockets).

## Self-hosting

The instance is fully self-contained — run your own on a free Cloudflare
account:

```sh
cd apps/cloud
wrangler d1 create codevisor-cloud        # put the id in wrangler.jsonc
wrangler d1 migrations apply codevisor-cloud --remote
wrangler kv namespace create PLUGIN_INDEX # put the id in wrangler.jsonc
wrangler secret put BETTER_AUTH_SECRET    # openssl rand -base64 32
wrangler secret put GITHUB_CLIENT_ID      # your own GitHub OAuth app
wrangler secret put GITHUB_CLIENT_SECRET  # callback: <your-url>/api/auth/callback/github
wrangler secret put GITHUB_TOKEN          # plugin-index poller (public repo read)
wrangler secret put PLUGINS_REFRESH_TOKEN # optional: enables POST /plugins/refresh
wrangler deploy
```

Set `PUBLIC_BASE_URL` (and a route/custom domain) in `wrangler.jsonc` to your
domain, then point clients at it (`codevisor auth login --server …`, or the
"Use a self-hosted server" option in app settings). `GET
/.well-known/codevisor` is the discovery endpoint clients validate before
trusting a server.

**Upgrading:** pull, `wrangler d1 migrations apply codevisor-cloud --remote`,
`wrangler deploy`. Per-user hub storage migrates itself lazily on first use.

## Deploys (hosted instance)

`.github/workflows/deploy-cloud.yml` deploys continuously from `main`
(path-filtered): typecheck + tests → D1 migrations → `wrangler deploy` to
`cloud.codevisor.dev`. Deploys drop all WebSockets by design;
clients auto-reconnect and terminal sessions resume via seq replay.

Schema changes must be **additive-only** (old code briefly runs against the
new schema during a deploy). `UserHub`'s internal SQLite migrations live in
`src/user-hub.ts` and are append-only, applied per-hub on wake.
