# Readability guide (draft)

Code should read like a description of what happens. A reader should be able to follow a top-level
function without opening its helpers, and open any helper and understand it in one glance.

The pilot for this guide is `packages/db/src/sync-journal.ts`.

## TypeScript

### 1. Top-level functions are a short list of named steps

Each line says what happens next. The details live in helpers.

```ts
// before
export const readSyncBatch = (db, since, sessionId?) =>
  db.transaction(() => {
    const subject = sessionId === undefined ? "global" : `session:${sessionId}`
    const floor = floorRows.maybe(db.prepare("select floor from …").get(subject))?.floor ?? 0
    // … 50 more lines of interleaved queries and checks
  })()

// after
export const readSyncBatch = (db, since, sessionId?) =>
  db.transaction(() => {
    const journal = journalFor(db, sessionId)
    const window = journal.replayWindow()
    if (outsideWindow(window, since)) return snapshotRequired(window.cursor)

    const pending = journal.sizesAfter(since, maxReplayRows + 1)
    if (tooBigToReplay(pending)) return snapshotRequired(window.cursor)

    return replay(journal.eventsAfter(since, maxReplayRows), window.cursor)
  })()
```

### 2. A helper does one thing and is a handful of lines

If you can't name a function without using "and", split it.

```ts
const outsideWindow = (window: ReplayWindow, since: number): boolean =>
  since < window.floor || since > window.cursor

const tooBigToReplay = (pending: ReadonlyArray<EventSize>): boolean =>
  pending.length > maxReplayRows || totalBytes(pending) > maxReplayBytes
```

### 3. Branch on a variant once, then use polymorphism

When two variants differ in several steps, build one object per variant in one place. Don't check
the variant again in every step.

```ts
// before: repeated in four places
sessionId === undefined ? db.prepare(globalQuery).all(…) : db.prepare(sessionQuery).all(sessionId, …)

// after: one branch
const journalFor = (db, sessionId?) => {
  if (sessionId === undefined) return globalJournal(db)
  return sessionJournal(db, sessionId)
}
```

### 4. No nested ternaries, and no ternaries that choose between code paths

A ternary is fine for picking a value (`count === 1 ? "item" : "items"`). If either side runs
queries, calls functions with side effects, or spans more than one line, use an `if`.

```ts
// before
const cursor =
  sessionId === undefined
    ? Math.max(floor, cursorRows.one(db.prepare("…").get()).cursor)
    : (cursorRows.maybe(db.prepare("…").get(sessionId))?.cursor ?? 0)

// after: each variant computes its own cursor
replayWindow: () => ({ floor: watermarkFloor(db, subject), cursor: sessionRevision(db, sessionId) })
```

### 5. Name every SQL query

Put queries in module-level constants (`fooSql`), or group them in an object when variants share
one shape. Call sites then read as intent, not SQL.

```ts
// before
db.prepare("delete from session_events where session_id = ? and revision <= ?").run(id, floor)

// after
const sessionSql = {
  deleteThrough: "delete from session_events where session_id = ? and revision <= ?"
}
db.prepare(sessionSql.deleteThrough).run(sessionId, sequence)
```

### 6. Wrap each query in a function named for what it returns

The function hides the row reader, the `?? 0` default, and the column name.

```ts
const watermarkFloor = (db: Database.Database, subject: string): number =>
  floorRows.maybe(db.prepare(watermarkFloorSql).get(subject))?.floor ?? 0
```

### 7. Use blank lines to separate steps

A group is one step: compute something, then check it. Don't put blank lines inside a group or
skip them between groups.

```ts
const journalBytes = addWatermarkBytes(db, journal.subject, addedBytes)
if (trimCanWait(journalBytes, sequence)) return

const tail = retainedTail(journal.newestSizes(maxJournalRows + trimInterval))
if (tail.floor === 0) return

journal.deleteThrough(tail.floor)
```

### 8. Return early with guard clauses

Handle the "nothing to do" and "bail out" cases first, in one line each. The happy path goes last
and is not indented.

### 9. Name the conditions

A boolean expression with more than one clause gets a named predicate (`trimCanWait`,
`tooBigToReplay`). When you invert a condition, keep the original comparison operators, because
`!(a <= b)` and `a > b` can differ for edge values such as `NaN`.

### 10. Name your numbers, and name each concept once

```ts
// before
if (bytes <= max && sequence % 64 !== 0) return
… .all(maxJournalRows + 64)

// after
const trimInterval = 64
if (trimCanWait(journalBytes, sequence)) return
journal.newestSizes(maxJournalRows + trimInterval)
```

### 11. Name small result shapes

Give a function's result an interface with readable fields (`ReplayWindow`, `RetainedTail`)
instead of an inline type, a tuple, or several `let` variables threaded through a loop.

### 12. Put the public API first and the details below it

Order a file as: exported types and constants, exported functions, then private helpers, then
SQL and row readers. Readers start with the story and dig down only as far as they need.

### 13. Keep files small and focused

The hard cap is 500 lines (`max-lines`). Aim for one concept per file, usually 100–250 lines.
Split a file when it starts holding a second concept, not when it reaches the cap.

## Swift

### S1. Small types, in one file each

A type and everything it does live in `TypeName.swift`. If that file is too big, the type is doing
too much. Extract a collaborator type; don't spread the original type across files.

### S2. No extension sprawl

Use extensions only for protocol conformance, and keep them in the type's own file. Don't write
`Foo+Layout.swift`, `Foo+Networking.swift`, and so on to hide a large type.

```swift
// before: SessionView.swift, SessionView+Toolbar.swift, SessionView+Actions.swift

// after: SessionView.swift composes SessionToolbar and SessionActions, each its own small type
```

### S3. Tiny functions with guard clauses

Functions are a handful of lines. Use `guard … else { return }` for the bail-out cases, and keep
the happy path unindented.

### S4. Small SwiftUI views

A view's `body` should show its layout at a glance: a stack of named subviews, not 80 lines of
modifiers. Pull a subview into its own `struct` as soon as it has its own state, its own
conditions, or more than a few modifiers. Prefer that to computed `some View` properties.

```swift
var body: some View {
  VStack {
    SessionHeader(session: session)
    TranscriptList(items: items)
    Composer(draft: $draft)
  }
}
```

### S5. No nested ternaries in Swift either

Use `if`/`switch` expressions to pick values, and named computed properties for conditions.

## What lint could enforce (not enabled yet)

| Rule                        | Tool             | Candidate                                                                                                              |
| --------------------------- | ---------------- | ---------------------------------------------------------------------------------------------------------------------- |
| 1, 2 Short functions        | oxlint           | `max-lines-per-function`, `max-statements`, `complexity`, `max-depth`                                                  |
| 4 No nested ternaries       | oxlint           | `no-nested-ternary` / `unicorn/no-nested-ternary`                                                                      |
| 4 No code-path ternaries    | —                | Review only. Too contextual to lint reliably.                                                                          |
| 5 Named SQL                 | oxlint JS plugin | Custom rule: `.prepare()` and `.exec()` take an identifier, not a string literal (like `scripts/lint/no-comments.mjs`) |
| 7 Blank lines between steps | —                | Review only. oxlint has no stylistic padding rules, and oxfmt keeps blank lines but doesn't add them.                  |
| 10 Magic numbers            | oxlint           | `no-magic-numbers`, with an ignore list (0, 1, -1)                                                                     |
| 13 Small files              | oxlint           | `max-lines` (already on, 500). Could ratchet lower.                                                                    |
| S1 Small types              | SwiftLint        | `type_body_length`, `file_length` (already on). Tighten the thresholds.                                                |
| S2 No extension sprawl      | SwiftLint        | `file_name` (already on, warning). A custom rule that bans `+` in file names.                                          |
| S3 Tiny functions           | SwiftLint        | `function_body_length`, `cyclomatic_complexity`, `nesting`                                                             |
| S4 Small views              | SwiftLint        | `closure_body_length` (catches long `body` closures)                                                                   |
| S5 Ternaries                | SwiftLint        | Custom regex rule for a nested `? … : … ? …`                                                                           |
