import CodevisorCore
import Foundation
import Observation

/// The editing buffer outlives any one pane, preview, or native view mount.
@MainActor @Observable
public final class FileDocumentModel {
  public let path: String
  public private(set) var text = ""
  public private(set) var snapshot: ServerFileDocument?
  /// Whether `text` differs from the snapshot's content. Stored, and
  /// recomputed only when either changes: views and saves read it many times
  /// per keystroke, and comparing whole files on every read was main-thread
  /// work proportional to the file.
  public private(set) var isDirty = false
  public private(set) var conflict: ServerFileDocument?
  public private(set) var isLoading = false
  public private(set) var isSaving = false
  public private(set) var error: String?
  public private(set) var draftError: String?
  @ObservationIgnored private let read: @Sendable () async throws -> ServerFileDocument
  @ObservationIgnored private let write: @Sendable (String, String) async throws -> ServerFileDocument
  @ObservationIgnored private let draftURL: URL?
  @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
  @ObservationIgnored private var draftTask: Task<Void, Never>?
  @ObservationIgnored private var autosaveTask: Task<Void, Never>?
  /// Bumped on every change to `text`, so a backup restored late can tell
  /// the buffer changed while it was loading.
  @ObservationIgnored private var textRevision: UInt64 = 0
  /// The device backup being read, from `init` until it has been applied.
  @ObservationIgnored private var draftLoad: Task<Void, Never>?
  /// The newest backup write requested; only its outcome sets `draftError`.
  @ObservationIgnored private var draftWriteGeneration: UInt64 = 0

  /// Draft backups for every document, encoded and written off the main
  /// thread. Writes to one draft file coalesce (only the newest pending
  /// backup is written), and a load runs after every write enqueued before
  /// it, so a reopened document reads the last backup a previous instance
  /// asked for.
  static let drafts = CoalescingWorkQueue(label: "com.codevisor.file-drafts")

  public var isEditable: Bool { snapshot?.writable == true }
  public var isMarkdown: Bool { MarkdownDocumentPath.isMarkdown(name) }
  public var name: String { FileDocumentLocation.name(path) }

  struct Draft: Codable, Sendable {
    let text: String
    let base: ServerFileDocument
  }

  init(
    path: String, draftURL: URL? = nil,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    read: @escaping @Sendable () async throws -> ServerFileDocument,
    write: @escaping @Sendable (String, String) async throws -> ServerFileDocument
  ) {
    self.path = path; self.draftURL = draftURL; self.read = read; self.write = write
    self.sleep = sleep
    // Read and decode the backup off the main thread. `refresh` waits for
    // it, so a restored draft still decides how the machine's copy is used.
    if let draftURL {
      draftLoad = Task { [weak self] in
        let draft = await Self.drafts.perform { Self.readDraft(at: draftURL) }
        self?.restore(draft)
      }
    }
  }

  deinit {
    draftTask?.cancel()
    autosaveTask?.cancel()
    draftLoad?.cancel()
  }

  /// Adopts a backup read from disk unless the document moved on while it
  /// loaded: the machine's copy already arrived, or the buffer was edited.
  private func restore(_ draft: Draft?) {
    draftLoad = nil
    guard let draft, snapshot == nil, textRevision == 0 else { return }
    snapshot = draft.base
    setText(draft.text)
  }

  private func setText(_ value: String) {
    text = value
    textRevision &+= 1
    updateDirtiness()
  }

  private func setSnapshot(_ value: ServerFileDocument) {
    snapshot = value
    updateDirtiness()
  }

  /// Runs when the buffer or its base changes, never per read. Most edits
  /// change the length, which settles it without comparing contents.
  private func updateDirtiness() {
    let base = snapshot?.content ?? ""
    isDirty = text.utf8.count != base.utf8.count || text != base
  }

  public func refresh() async {
    guard !isLoading, !isSaving else { return }
    isLoading = true
    defer { isLoading = false }
    if let draftLoad { await draftLoad.value }
    let originalVersion = snapshot?.version
    do {
      let latest = try await read()
      try Task.checkCancellation()
      // A background read started before a save must not restore the old
      // contents after that save has committed.
      guard !isSaving, snapshot?.version == originalVersion else { return }
      if let previous = snapshot, isDirty, latest.version != previous.version {
        if latest.content == text {
          setSnapshot(latest); conflict = nil; persistDraft()
        } else {
          conflict = latest
        }
      } else if !isDirty || snapshot == nil {
        snapshot = latest
        setText(latest.content ?? "")
        conflict = nil
        persistDraft()
      } else {
        // Refresh permissions even when the contents have not changed.
        setSnapshot(latest)
      }
      if !isDirty { error = nil }
      // Resume recovered drafts and interrupted saves after reconnecting.
      if autosaveTask == nil { scheduleAutosave() }
    } catch {
      if !isTaskCancellation(error) { self.error = serverErrorMessage(error) }
    }
  }

  public func edit(_ value: String) {
    setText(value)
    scheduleAutosave()
    guard draftURL != nil else { return }
    draftTask?.cancel()
    draftTask = Task { [weak self, sleep] in
      do { try await sleep(.milliseconds(300)); try Task.checkCancellation() } catch { return }
      self?.persistDraft()
    }
  }

  private func scheduleAutosave() {
    autosaveTask?.cancel()
    autosaveTask = nil
    guard isDirty, isEditable, conflict == nil, !isSaving else { return }
    autosaveTask = Task { [weak self, sleep] in
      do { try await sleep(.milliseconds(500)); try Task.checkCancellation() } catch { return }
      guard let self else { return }
      // Edits can cancel the debounce, never a write already in flight.
      self.autosaveTask = nil
      await self.save()
    }
  }

  /// Back up before a pane disappears or the app backgrounds. The backup's
  /// contents are captured now and written on the draft queue; like the
  /// save, it belongs to the document and outlives the view's task.
  public func flushAutosave() {
    persistDraft()
    autosaveTask?.cancel()
    autosaveTask = nil
    Task { await save() }
  }

  public func retry() async {
    persistDraft()
    await refresh()
    await save()
  }

  public func save() async {
    autosaveTask?.cancel()
    autosaveTask = nil
    guard !isSaving, isDirty, isEditable, conflict == nil else { return }
    isSaving = true
    defer { isSaving = false }
    while isDirty, isEditable, conflict == nil, let snapshot {
      let submitted = text
      persistDraft()
      do {
        let saved = try await write(submitted, snapshot.version)
        setSnapshot(saved)
        self.error = nil
        persistDraft()
        // Drain edits made during the write using its returned revision.
      } catch {
        self.error = "Couldn’t save changes: \(serverErrorMessage(error))"
        if serverErrorCode(error) == "file_conflict" {
          self.conflict = try? await read()
        }
        persistDraft()
        return
      }
    }
  }

  /// Choosing Keep My Edits acknowledges the compared disk revision. A later
  /// save still checks that revision, so a second external edit cannot vanish.
  public func keepEdits() {
    guard let conflict else { return }
    setSnapshot(conflict); self.conflict = nil; error = nil; persistDraft()
    flushAutosave()
  }

  public func useDiskVersion() {
    guard let conflict else { return }
    snapshot = conflict; setText(conflict.content ?? ""); self.conflict = nil; error = nil
    autosaveTask?.cancel()
    autosaveTask = nil
    persistDraft()
  }

  /// Backs up the buffer on this device, or removes the backup once the
  /// buffer matches the machine's copy. The contents are captured now; the
  /// encode and the atomic write run on the draft queue.
  public func persistDraft() {
    draftTask?.cancel()
    guard let draftURL, let snapshot else { return }
    draftWriteGeneration &+= 1
    let generation = draftWriteGeneration
    let draft = isDirty ? Draft(text: text, base: snapshot) : nil
    Self.drafts.enqueue(key: draftURL.path) { [weak self] in
      let succeeded = Self.writeDraft(draft, to: draftURL)
      Task { @MainActor in self?.finishDraftWrite(generation: generation, succeeded: succeeded) }
    }
  }

  private func finishDraftWrite(generation: UInt64, succeeded: Bool) {
    // A superseded write finishing late must not report over a newer one.
    guard generation == draftWriteGeneration else { return }
    draftError =
      succeeded ? nil : "Couldn’t back up your edits on this device. Keep this file open until autosave finishes."
  }

  nonisolated private static func readDraft(at url: URL) -> Draft? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Draft.self, from: data)
  }

  nonisolated private static func writeDraft(_ draft: Draft?, to url: URL) -> Bool {
    do {
      if let draft {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: url, options: .atomic)
      } else if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
      return true
    } catch {
      return false
    }
  }
}
