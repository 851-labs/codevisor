# @codevisor/cloud

The Codevisor Cloud instance: sign in once, see all your machines, and connect
to them from anywhere through an **end-to-end encrypted relay** — no VPN, no
port forwarding.

One Cloudflare Worker contains the whole plane:

- **Auth** — [Better Auth](https://better-auth.com) on D1: Apple and GitHub OAuth for
  apps, RFC 8628 device flow for `codevisor auth login`, long-lived revocable
  api keys as machine credentials.
- **`UserHub` Durable Object** — one per account. Apps and machines dial in
  over WebSockets (hibernation: idle machines cost ~nothing); the hub tracks
  presence and routes relay frames between peers. Placement follows the first
  device to touch the account: every hub access passes a location hint derived
  from the request's geolocation (`src/location-hint.ts`), so hubs spawn near
  their users instead of wherever Cloudflare's default placement lands.
- **Relay protocol** — multiplexed channels (`@codevisor/api` cloud-protocol).
  Relay traffic is binary: each WebSocket message carries one or more
  envelopes (small JSON header + raw ciphertext payload — no base64, and
  senders coalesce bursts into one message). Channel payloads are sealed
  end-to-end between devices (`@codevisor/cloud-crypto`: X25519 +
  ChaCha20-Poly1305); the hub only ever sees ciphertext and envelope
  addressing. Even `channelType` is encrypted.
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

### Sign in with Apple

iOS presents Apple's native authorization sheet directly. The app obtains a
single-use Cloud challenge, sets its nonce on the Apple request, then sends the
authorization code to Cloud. Cloud exchanges it for the configured native App ID
and verifies the signed identity token, audience, expiry, and nonce before
creating a session. Link challenges also bind the initiating account and session.

macOS uses `ASWebAuthenticationSession` with the associated Services ID; this
supports Developer ID distribution. Group the Services ID with the primary iOS
App ID so their verified Apple `sub` values resolve to the same
`account(provider_id, account_id)` and Cloud user. Email is not an identity key.

In Apple Developer, enable Sign in with Apple on the primary iOS App ID, associate
a Services ID with it, and register the Cloud domain and return URL:
`https://cloud.codevisor.dev/api/auth/callback/apple`. Create a Sign in with Apple
key associated with that primary App ID. For the hosted instance these are:

- Primary App ID: `com.dylanplayer.codevisor.ios`
- Native App ID / `APPLE_NATIVE_CLIENT_ID`: `com.dylanplayer.codevisor.ios` (public Worker variable)
- Services ID / `APPLE_CLIENT_ID`: `com.dylanplayer.codevisor.cloud`
- `APPLE_TEAM_ID`: `C4M7D4G7LG`
- `APPLE_KEY_ID`: `265B2BLJG5`

Store `APPLE_CLIENT_ID`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, and `APPLE_PRIVATE_KEY`
as Worker secrets. `APPLE_PRIVATE_KEY` is the complete PKCS#8 `.p8` file; keep it
out of Git and app bundles. For example, from `apps/cloud`:

```sh
bunx wrangler secret put APPLE_CLIENT_ID
bunx wrangler secret put APPLE_TEAM_ID
bunx wrangler secret put APPLE_KEY_ID
bunx wrangler secret put APPLE_PRIVATE_KEY < /secure/path/AuthKey_KEYID.p8
```

Push the implementation to `main` to run the Cloud deployment workflow. CI applies
the D1 migration and deploys the Worker; do not deploy the hosted instance manually.

Client secret JWTs are generated with a five-minute lifetime when needed; they
do not require scheduled manual rotation. Rotate the private key through Apple
Developer and update the two corresponding Worker secrets when necessary.

Existing users can add a provider under **Account → Connected Accounts** in either
native app. Connected providers are listed there. The browser bridge for GitHub
and macOS Apple linking only establishes the app's session and redirects to the
selected provider; it has no account picker or completion UI. All native handoffs
return directly to the app, including failures. Linking supports Hide My Email,
never merges automatically by email, and cannot move an identity owned by another
Cloud user. Returning logins retain the original profile when Apple omits it.

The iOS target includes `com.apple.developer.applesignin`. CI attaches the declared
entitlements to the unsigned archive before cloud distribution signing, uses
automatic provisioning at export, and verifies the exported entitlement. The provisioning
profile must include Sign in with Apple. A physical-device development build must
use a registered, capable App ID; a worktree's unique simulator bundle ID does not
have production Apple credentials.

**Delete Cloud Account** in either app requires a recent session, revokes the
Apple refresh token, deletes Cloud account/session/machine credentials, and
disconnects and clears the account's relay hub. Deletion stops before removing
records if Apple revocation fails, so the user can retry. Local files and chats
stay on their machines. Individual provider unlinking is disabled so the Apple
refresh token remains available for deletion.

Validation covers separate Mac/iPhone browser sessions and native handoffs,
identity verification failures, state/token replay, linking, and deletion using
fake Apple endpoints and real D1/DO storage. Before App Store submission, also
complete a real Apple sign-in on a Mac and an iPhone, confirm both see the same
machines, and test deletion with a disposable Cloud account. This change does
not configure Apple's optional server-to-server account-change notifications.

### Continuous deployment

`.github/workflows/deploy-cloud.yml` deploys continuously from `main`
(path-filtered): typecheck + tests → D1 migrations → `wrangler deploy` to
`cloud.codevisor.dev` → health check. A deploy restarts each hub and drops
its WebSockets — Durable Object sockets cannot be drained — but clients ride
that out on their own: they reconnect with jittered backoff and resume their
sessions inside the hub's grace window, with frames buffered meanwhile
replayed in order. (An earlier staged canary rollout was removed: session
resume made the global reconnect blip invisible, and the orchestration wasn't
worth its complexity.)

Schema changes must be **additive-only** (old code briefly runs against the
new schema during a deploy). `UserHub`'s internal SQLite migrations live in
`src/user-hub.ts` and are append-only, applied per-hub on wake.
