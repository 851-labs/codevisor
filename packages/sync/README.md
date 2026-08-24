# @codevisor/sync

The config plane's one replication primitive: small documents of
**last-writer-wins entries** ordered by **hybrid logical clocks**, gossiped
between machines by whichever clients can reach them.

## The model

- A **document** is a namespace (`settings`, `skills`, …) holding a flat map
  of keys → `{ value, deleted?, timestamp }`.
- A **timestamp** is `(wallMs, counter, deviceId)` — a hybrid logical clock.
  Comparison is total and identical on every replica: wall clock, then
  counter, then device id as the deterministic tiebreak.
- **Merging** is per-key LWW: the newer stamp wins. Merging is idempotent
  and commutative, so replicas converge regardless of the order (or number
  of times) updates arrive.
- **Deletions are tombstones** (`deleted: true`), so a removal beats an
  older write even on a replica that never saw the key.

## The topology

There is deliberately **no authority server**. Every machine's server holds
a replica (`GET`/`PUT /v1/sync/:namespace` — the PUT response is the merged
document, so one round trip pushes _and_ pulls). Clients are the gossip
edges: a client connected to N machines folds their replicas together and
writes the merged result back, and servers publish `sync.changed` events so
other connected clients adopt changes live. A machine that was offline
converges the next time any client reaches it.

## The limits (on purpose)

- **LWW only.** No multi-value registers, no merge functions, no counters.
  Config conflicts are rare and losing a concurrent settings write is
  acceptable; anything that isn't (worktrees, sessions) belongs to the
  single-writer ownership model, not this package.
- **Whole values.** Entries replace atomically; don't store large structures
  under one key if fields change independently — use one key per field.
- **Documents stay small.** Full-state exchange is the simplicity that makes
  this trivially convergent. Reference big payloads (skill archives) by
  content hash and move the bytes over the blob endpoints instead.
