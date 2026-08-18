# Cloud sync reliability

How a phone (or any remote app) following a desktop chat stays correct across
flaky networks, suspensions, and machine restarts — and the invariant every
future transport change must preserve.

## Architecture

```
app ──(hub WS)── Cloud relay (Durable Object per account) ──(hub WS)── desktop server
                        pure router, E2E encrypted                    SQLite = truth
```

- The app opens **one WebSocket to the account's hub** (`apps/cloud/src/user-hub.ts`)
  and multiplexes end-to-end-encrypted _relay channels_ over it
  (`packages/swift/CodevisorCloud`, `packages/cloud-client`). Every HTTP request
  and WebSocket the app makes is tunnelled to the desktop's own local server.
- **The cloud persists nothing** but machine registry rows. E2E encryption makes
  store-and-forward structurally impossible: the hub can address envelopes, never
  read or replay them. All recovery therefore lives at the endpoints.
- **The desktop's SQLite is the source of truth.** Every runtime event is
  persisted atomically with the chat-row projection (`packages/db`), keyed by a
  strictly monotonic per-session `revision`. `session_events` is never pruned.
- Clients follow a chat by opening `/v1/sessions/:id/events/socket?since=<cursor>`
  through the relay; the server replays everything after the cursor, then goes
  live (`apps/server/src/routes/events.ts`).

## The invariant

> A client that believes a turn is in flight must be able to verify that belief
> against durable truth within bounded time, and the durable truth must converge
> to reality on its own.

Concretely: every layer either **fails loudly** (an error a client reacts to) or
**heals itself** (a periodic re-derivation from durable state). Silent failure
modes are bugs, full stop — one lost frame must never be able to wedge a chat
forever.

## Defense layers

| Failure                                                | Detection / repair                                                                                                                                                                     | Bound     |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- |
| Machine's hub socket dies                              | Hub broadcasts offline `presence` + `machine-offline` error → app closes that machine's channels → streams resume from cursor                                                          | seconds   |
| Machine reconnects (channels silently orphaned)        | Hub broadcasts `machine-reset` on machine hello (before the online presence) → app drops dead channels, re-opens on the fresh socket                                                   | seconds   |
| Zombie machine socket black-holes routing              | Hub closes superseded sockets on hello (code 4003); relay send failures report `machine-offline` / `peer-gone` instead of dropping                                                     | seconds   |
| Frames for unknown channels (machine side)             | Answered with `close("peer-disconnected")`, never silently dropped (`machine-connection.ts`)                                                                                           | seconds   |
| Any silent death (half-open TCP, unknown modes)        | Session sockets carry a 25s keepalive envelope; clients arm a 90s receive deadline after the first keepalive and reconnect-from-cursor on expiry                                       | ~90s      |
| Missed/lost terminal event on the client               | 300s stalled-turn detector reconciles from durable history (`SessionModel`)                                                                                                            | ~5 min    |
| Stuck `chat_items.status = 'streaming'` on the desktop | 60s sweep fails quiet orphaned rows **through the event pipeline** so connected clients unstick live (`reconcileStaleStreamingTurns`); startup reconciliation covers dead-process rows | ~6 min    |
| App suspension hid state changes                       | Foreground/network recovery reconciles every cached in-flight chat; re-entering a stalled chat reconciles on `connectIfNeeded`; stalled controllers are evictable                      | on resume |
| Oversized event (> hub 2 MiB frame cap)                | Relayed WS messages above 256 KiB are chunked (`part…text-end/binary-end`) and reassembled app-side, instead of a dropped frame → seq-gap abort → replay livelock                      | n/a       |

## Cursor rules

- The session event cursor is the server-assigned `session_events.revision`.
  Clients advance it per received event and reconnect with `?since=<cursor>`.
- `since >= Number.MAX_SAFE_INTEGER` means **live-only**. The one client-side
  sentinel is `ServerSessionTransport.liveOnlyEventCursor`; a sentinel cursor
  adopts the first real event id (`advanceEventCursor`) so later reconnects
  replay instead of staying live-only forever.
- **Keepalives are not events**: they are filtered before cursor logic (a
  sentinel must never adopt one) and are stamped with the socket's own cursor
  so old clients' `max(cursor, id)` is always a no-op.

## Compatibility rules for protocol changes

- Apps ignore unknown hub frame kinds and unknown relayed-WS frame kinds.
  New frames must be **additive** and degrade safely for clients that skip
  them (`machine-reset` → old apps fall back to presence/error healing;
  chunked WS frames → old apps skip the one oversized message).
- Never emit anything on the **global** event socket that a live-only
  subscriber could adopt as a cursor.
- Deploy order for hub changes: cloud Worker first (must be compatible with
  all shipped apps and desktops), then desktop, then apps.

## Known non-features

- Relay `credit` flow-control frames are sent by apps but not consumed by the
  desktop bridge — decorative today. They stay on the wire because shipped
  apps emit them inside the per-channel seq sequence; removing them would
  break seq accounting for existing clients.
- There is no end-to-end integration harness that kills individual legs of
  app↔cloud↔desktop in one test; each link's failure handling is covered by
  its own package's tests. Build the harness before the next protocol-level
  change if that change is timing-sensitive.
