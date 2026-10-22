---
name: code-style
description: Codevisor's code style and readability rules for TypeScript and Swift. Use whenever writing, refactoring, or reviewing TypeScript or Swift code in this repo, including small edits and code-review passes.
---

# Code style

Write code that reads like a description of what happens. A reader must be
able to follow a top-level function without opening its helpers, and to
understand any helper at a glance.

Apply these rules to code you write or change. When reviewing, flag
violations in the diff.

## TypeScript

### 1. Write top-level functions as a short list of named steps

Each line says what happens next. Move the details into helpers.

Before:

```ts
export const readSyncBatch = (db, since, sessionId?) =>
  db.transaction(() => {
    const subject = sessionId === undefined ? "global" : `session:${sessionId}`
    const floor = floorRows.maybe(db.prepare("select floor from …").get(subject))?.floor ?? 0
    …
  })()
```

After:

```ts
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

### 2. Make each helper do one thing in a handful of lines

If you can't name a function without "and", split it.

```ts
const outsideWindow = (window: ReplayWindow, since: number): boolean =>
  since < window.floor || since > window.cursor

const tooBigToReplay = (pending: ReadonlyArray<EventSize>): boolean =>
  pending.length > maxReplayRows || totalBytes(pending) > maxReplayBytes
```

### 3. Branch on a variant once, then use polymorphism

When two variants differ in several steps, build one object per variant in
one place. Don't re-check the variant in every step.

Before, repeated in four places:

```ts
sessionId === undefined ? db.prepare(globalQuery).all(…) : db.prepare(sessionQuery).all(sessionId, …)
```

After, one branch:

```ts
const journalFor = (db, sessionId?) => {
  if (sessionId === undefined) return globalJournal(db)
  return sessionJournal(db, sessionId)
}
```

### 4. No nested ternaries, and no ternaries that choose between code paths

Use a ternary only to pick a value (`count === 1 ? "item" : "items"`). If
either side runs a query, calls a function with side effects, or spans more
than one line, use an `if`.

Before:

```ts
const cursor =
  sessionId === undefined
    ? Math.max(floor, cursorRows.one(db.prepare("…").get()).cursor)
    : (cursorRows.maybe(db.prepare("…").get(sessionId))?.cursor ?? 0)
```

After, each variant computes its own cursor:

```ts
replayWindow: () => ({ floor: watermarkFloor(db, subject), cursor: sessionRevision(db, sessionId) })
```

### 5. Name every SQL query

Put queries in module-level constants (`fooSql`), or group them in an object
when variants share one shape. Call sites then read as intent, not SQL.

Before:

```ts
db.prepare("delete from session_events where session_id = ? and revision <= ?").run(id, floor)
```

After:

```ts
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

### 7. Separate steps with blank lines

A step is one group: compute something, then check it. Put one blank line
between groups and none inside a group.

```ts
const journalBytes = addWatermarkBytes(db, journal.subject, addedBytes)
if (trimCanWait(journalBytes, sequence)) return

const tail = retainedTail(journal.newestSizes(maxJournalRows + trimInterval))
if (tail.floor === 0) return

journal.deleteThrough(tail.floor)
```

### 8. Return early with guard clauses

Handle the "nothing to do" and "bail out" cases first, one line each. Put
the happy path last, unindented.

### 9. Name the conditions

Give any boolean expression with more than one clause a named predicate
(`trimCanWait`, `tooBigToReplay`). When you invert a condition, keep the
original comparison operators: `!(a <= b)` and `a > b` differ for values
such as `NaN`.

### 10. Name your numbers, and name each concept once

Before:

```ts
if (bytes <= max && sequence % 64 !== 0) return
… .all(maxJournalRows + 64)
```

After:

```ts
const trimInterval = 64
if (trimCanWait(journalBytes, sequence)) return
journal.newestSizes(maxJournalRows + trimInterval)
```

### 11. Name small result shapes

Give a function's result an interface with readable fields (`ReplayWindow`,
`RetainedTail`) instead of an inline type, a tuple, or several `let`
variables threaded through a loop.

### 12. Put the public API first and the details below it

Order a file as: exported types and constants, exported functions, private
helpers, then SQL and row readers. Readers start with the story and dig down
only as far as they need.

### 13. Keep files small and focused

The hard cap is 500 lines (`max-lines`). Aim for one concept per file,
usually 100–250 lines. Split a file when it starts holding a second concept,
not when it reaches the cap.

## Swift

### S1. Small types, one file each

Keep a type and everything it does in `TypeName.swift`. If that file is too
big, the type is doing too much: extract a collaborator type instead of
spreading the original across files.

Before, one type owns sessions and drafts:

```swift
final class SessionStore {
  private(set) var sessions: [Session] = []
  private var drafts: [Session.ID: String] = [:]

  func add(_ session: Session) {
    sessions.append(session)
  }

  func draft(for id: Session.ID) -> String {
    drafts[id, default: ""]
  }

  func saveDraft(_ text: String, for id: Session.ID) {
    drafts[id] = text
  }

  func clearDraft(for id: Session.ID) {
    drafts[id] = nil
  }
}
```

After, `SessionStore.swift` composes a `DraftStore` that lives in
`DraftStore.swift`:

```swift
final class SessionStore {
  private(set) var sessions: [Session] = []
  let drafts = DraftStore()

  func add(_ session: Session) {
    sessions.append(session)
  }
}
```

```swift
final class DraftStore {
  private var texts: [Session.ID: String] = [:]

  func text(for id: Session.ID) -> String {
    texts[id, default: ""]
  }

  func save(_ text: String, for id: Session.ID) {
    texts[id] = text
  }

  func clear(for id: Session.ID) {
    texts[id] = nil
  }
}
```

### S2. No extension sprawl

Use extensions only for protocol conformance, and keep them in the type's
own file. Don't write `Foo+Layout.swift`, `Foo+Actions.swift`, and so on to
hide a large type.

Before, `SessionView+Toolbar.swift` and `SessionView+Actions.swift`:

```swift
extension SessionView {
  var toolbar: some View {
    HStack {
      Button("Rename", action: rename)
      Button("Archive", action: archive)
    }
  }
}
```

```swift
extension SessionView {
  func rename() {
    store.rename(session)
  }

  func archive() {
    store.archive(session)
  }
}
```

After, `SessionToolbar.swift` is its own small type:

```swift
struct SessionToolbar: View {
  let session: Session
  let store: SessionStore

  var body: some View {
    HStack {
      Button("Rename") { store.rename(session) }
      Button("Archive") { store.archive(session) }
    }
  }
}
```

`SessionView.swift` composes it:

```swift
struct SessionView: View {
  let session: Session
  let store: SessionStore

  var body: some View {
    VStack {
      SessionToolbar(session: session, store: store)
      TranscriptList(items: session.items)
    }
  }
}
```

A conformance stays in the type's own file, `Session.swift`:

```swift
struct Session: Identifiable {
  let id: UUID
  var title: String
  var items: [TranscriptItem]
}

extension Session: CustomStringConvertible {
  var description: String { title }
}
```

### S3. Tiny functions with guard clauses

Keep functions to a handful of lines. Use `guard … else { return }` for the
bail-out cases, and keep the happy path unindented.

Before:

```swift
func send(_ draft: String) {
  if !draft.isEmpty {
    if let session = selectedSession {
      if !session.isArchived {
        transport.send(draft, to: session.id)
        drafts.clear(for: session.id)
      }
    }
  }
}
```

After:

```swift
func send(_ draft: String) {
  guard !draft.isEmpty else { return }
  guard let session = selectedSession, !session.isArchived else { return }

  transport.send(draft, to: session.id)
  drafts.clear(for: session.id)
}
```

### S4. Small SwiftUI views

Make a view's `body` show its layout at a glance: a stack of named subviews,
not 60 lines of modifiers. Pull a subview into its own `struct` as soon as
it has its own state, its own conditions, or more than a few modifiers.
Prefer that to computed `some View` properties.

Before, trimmed from a 60-line `body`:

```swift
@State private var draft = ""

var body: some View {
  VStack(alignment: .leading, spacing: 12) {
    HStack {
      Text(session.title)
        .font(.headline)
        .lineLimit(1)
      Spacer()
      if session.isRunning {
        ProgressView()
          .controlSize(.small)
      }
    }
    .padding(.horizontal, 16)
    ScrollView {
      LazyVStack(alignment: .leading) {
        ForEach(session.items) { item in
          Text(item.text)
            .textSelection(.enabled)
            .padding(8)
        }
      }
    }
    TextField("Message", text: $draft, axis: .vertical)
      .textFieldStyle(.plain)
      .lineLimit(1...6)
      .padding(10)
      .onSubmit {
        send(draft)
        draft = ""
      }
  }
}
```

After:

```swift
var body: some View {
  VStack(alignment: .leading, spacing: 12) {
    SessionHeader(session: session)
    TranscriptList(items: session.items)
    Composer(onSend: send)
  }
}
```

`Composer` owns its draft, so the parent no longer holds that state:

```swift
struct Composer: View {
  let onSend: (String) -> Void
  @State private var draft = ""

  var body: some View {
    TextField("Message", text: $draft, axis: .vertical)
      .textFieldStyle(.plain)
      .lineLimit(1...6)
      .padding(10)
      .onSubmit(submit)
  }

  private func submit() {
    guard !draft.isEmpty else { return }

    onSend(draft)
    draft = ""
  }
}
```

### S5. No nested ternaries

Use `if`/`switch` expressions to pick values, and named computed properties
for conditions.

Before:

```swift
let tint: Color = session.isArchived ? .secondary : session.error != nil && session.retryCount > 2 ? .red : .primary
let label = session.state == .running ? "Working" : session.state == .waiting ? "Needs input" : "Idle"
```

After:

```swift
private var hasGivenUp: Bool {
  session.error != nil && session.retryCount > maxRetries
}

private var tint: Color {
  if session.isArchived {
    .secondary
  } else if hasGivenUp {
    .red
  } else {
    .primary
  }
}

private var label: String {
  switch session.state {
  case .running: "Working"
  case .waiting: "Needs input"
  case .idle: "Idle"
  }
}
```

### S6. Keep the main actor for UI and move heavy work off it

Know the isolation default of the target you're editing:

- **App targets** (`apps/macos`, `apps/ios`) and `TranscriptSurface` default
  to `MainActor` isolation. Every declaration is on the main actor unless you
  mark it `nonisolated`. The apps also build with strict concurrency
  `complete` and approachable concurrency, so a plain `nonisolated async`
  function runs on its caller's actor.
- **Other `packages/swift` targets** use the Swift 6 language mode with no
  default isolation. Declarations are nonisolated unless you mark them.

Put these on the main actor: SwiftUI views, AppKit and UIKit types,
`@Observable` models that views read, and anything else that touches UI
state.

Keep these off it: parsing (markdown, JSON), disk and file I/O, networking,
image decoding, diffing, and other heavy compute. Put that work in a
`@concurrent nonisolated` async function or an actor, `await` it, and assign
the result on the main actor.

- Isolate whole types. In package targets, mark the type `@MainActor`
  instead of individual methods. In app targets it's already the default, so
  don't restate it.
- Mark pure helpers and the value types they return `nonisolated`. In app
  targets they're main-actor isolated otherwise and can't be called from
  background work. A synchronous `nonisolated` function still runs on the
  caller's thread; it doesn't move work off the main actor.
- Use `@concurrent` only for work that's actually heavy. Prefer it to
  `Task.detached`. Use `Task.detached` only when the new task must not
  inherit the caller's actor, priority, or task-local values.
- Don't use `DispatchQueue.main.async`, `DispatchQueue.global().async`, or
  semaphores in new code. Use actor isolation and `await` instead.
- Pass `Sendable` value types (structs, enums) across isolation boundaries,
  not classes with mutable state.
- Never block the main actor with a synchronous wait: no semaphore `wait()`,
  `DispatchQueue.main.sync`, `Thread.sleep`, or synchronous file reads.

Before, in an app target, reading and parsing run on the main actor:

```swift
@Observable
final class DocumentModel {
  var blocks: [MarkdownBlock] = []

  func load(_ url: URL) throws {
    let text = try String(contentsOf: url, encoding: .utf8)
    blocks = MarkdownParser.parse(text)
  }
}
```

After, the read and parse run in a `@concurrent` function, and the model
assigns the result on the main actor:

```swift
@Observable
final class DocumentModel {
  var blocks: [MarkdownBlock] = []

  func load(_ url: URL) async throws {
    blocks = try await Self.readBlocks(from: url)
  }

  @concurrent
  private nonisolated static func readBlocks(from url: URL) async throws -> [MarkdownBlock] {
    let text = try String(contentsOf: url, encoding: .utf8)
    return MarkdownParser.parse(text)
  }
}
```

```swift
nonisolated struct MarkdownBlock: Sendable, Equatable {
  var text: String
}

nonisolated enum MarkdownParser {
  static func parse(_ text: String) -> [MarkdownBlock] {
    text.split(separator: "\n\n").map { MarkdownBlock(text: String($0)) }
  }
}
```

Before, hopping to the main thread by hand:

```swift
final class ConnectionStatus: ObservableObject {
  @Published var isOnline = false

  func update(_ isOnline: Bool) {
    DispatchQueue.main.async {
      self.isOnline = isOnline
    }
  }
}
```

After, in a package target, the type is isolated and callers off the main
actor `await status.update(isOnline)`:

```swift
@MainActor
@Observable
final class ConnectionStatus {
  var isOnline = false

  func update(_ isOnline: Bool) {
    self.isOnline = isOnline
  }
}
```

## Enforced by lint

`bun run check` and the pre-commit hook fail on these:

- **No nested ternaries** (rule 4): oxlint `no-nested-ternary`, with no
  exemptions.
- **No effect-choosing ternaries** (rule 4): `codevisor/no-effect-ternary`
  fails a ternary with an `await`, `yield`, or assignment in a branch
  (nested functions don't count), and a ternary whose value is discarded. It
  doesn't judge calls, so `a ? f() : g()` is still yours to review. Write
  `a ?? (c ? await f() : undefined)` as `let x = a` then
  `if (x === undefined && c) x = await f()`. Only when `a`'s type allows
  null, start from `let x = a ?? undefined`, so a null `a` still comes out
  as `undefined`.
- **Named SQL** (rule 5): `codevisor/named-sql` fails a SQL string literal
  passed straight to `.prepare()`, `.exec()`, `.run()`, or `.query()`. When
  a statement needs a runtime identifier, build it in a named function that
  quotes the identifier, like `dropTriggerSql(name)`. Tests,
  test support, and the `packages/db` migration and upgrade files are
  excluded by path in `.oxlintrc.json`.
- **File size** (rule 13, S1): oxlint `max-lines` 500; SwiftLint
  `file_length` 500 and `type_body_length` 400.
- **Swift function length** (S3): SwiftLint `function_body_length` 50. The
  functions that were already longer are grandfathered in
  `.swiftlint-baseline.json`, which matches each one by its line count and
  declaration line, so any change to either fails. Bring the function to 50
  lines or fewer; if you only shrink it, run `bun run swift:lint:baseline` and
  check that the diff only shortens entries. The rule skips computed
  properties, so SwiftUI `body` (S4) isn't checked.
- `file_name` for Swift, and no comments anywhere (`codevisor/no-comments`).

The custom rules live in `scripts/lint`. Their exemptions are listed, with a
reason for each, in `scripts/lint/exemptions.json`: each entry is a file plus
the exempted code with whitespace collapsed. The rules fail when an entry no
longer matches, so delete it when you fix the code. Add one only when a rewrite
would change behavior.

Every other rule is yours to apply while writing and to check while
reviewing. The Swift compiler catches data races, but not heavy work left on
the main actor.
