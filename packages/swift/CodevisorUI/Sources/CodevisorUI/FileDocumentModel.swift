import CodevisorCore
import Foundation
import Observation

/// The editing buffer outlives any one pane, preview, or native view mount.
@MainActor @Observable
public final class FileDocumentModel {
  public let path: String
  public var text = ""
  public private(set) var snapshot: ServerFileDocument?
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

  public var isDirty: Bool { text != (snapshot?.content ?? "") }
  public var isEditable: Bool { snapshot?.writable == true }
  public var isMarkdown: Bool { MarkdownDocumentPath.isMarkdown(name) }
  public var name: String { FileDocumentLocation.name(path) }

  struct Draft: Codable {
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
    if let draftURL, let data = try? Data(contentsOf: draftURL),
      let draft = try? JSONDecoder().decode(Draft.self, from: data)
    {
      text = draft.text
      snapshot = draft.base
    }
  }

  deinit {
    draftTask?.cancel()
    autosaveTask?.cancel()
  }

  public func refresh() async {
    guard !isLoading, !isSaving else { return }
    isLoading = true
    let originalVersion = snapshot?.version
    defer { isLoading = false }
    do {
      let latest = try await read()
      try Task.checkCancellation()
      // A background read started before a save must not restore the old
      // contents after that save has committed.
      guard !isSaving, snapshot?.version == originalVersion else { return }
      if let previous = snapshot, isDirty, latest.version != previous.version {
        if latest.content == text {
          snapshot = latest; conflict = nil; persistDraft()
        } else {
          conflict = latest
        }
      } else if !isDirty || snapshot == nil {
        snapshot = latest
        text = latest.content ?? ""
        conflict = nil
        persistDraft()
      } else {
        // Refresh permissions even when the contents have not changed.
        snapshot = latest
      }
      if !isDirty { error = nil }
      // Resume recovered drafts and interrupted saves after reconnecting.
      if autosaveTask == nil { scheduleAutosave() }
    } catch {
      if !isTaskCancellation(error) { self.error = serverErrorMessage(error) }
    }
  }

  public func edit(_ value: String) {
    text = value
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

  /// Back up synchronously before a pane disappears or the app backgrounds.
  /// The write belongs to the document and outlives the view's task.
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
        self.snapshot = saved
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
    snapshot = conflict; self.conflict = nil; error = nil; persistDraft()
    flushAutosave()
  }

  public func useDiskVersion() {
    guard let conflict else { return }
    snapshot = conflict; text = conflict.content ?? ""; self.conflict = nil; error = nil
    autosaveTask?.cancel()
    autosaveTask = nil
    persistDraft()
  }

  public func persistDraft() {
    draftTask?.cancel()
    guard let draftURL, let snapshot else { return }
    do {
      if isDirty {
        try FileManager.default.createDirectory(
          at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Draft(text: text, base: snapshot)).write(to: draftURL, options: .atomic)
      } else if FileManager.default.fileExists(atPath: draftURL.path) {
        try FileManager.default.removeItem(at: draftURL)
      }
      draftError = nil
    } catch { draftError = "Couldn’t back up your edits on this device. Keep this file open until autosave finishes." }
  }

}
