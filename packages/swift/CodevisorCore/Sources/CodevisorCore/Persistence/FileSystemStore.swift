import Foundation

/// A `PersistenceStore` backed by JSON files in the app's Application Support
/// directory.
///
/// Writes are asynchronous: callers are `@MainActor` models on hot
/// interaction paths (turn end, pane tab clicks, sidebar mutations), and a
/// disk stall — Spotlight, low disk, a network home directory — must never
/// block the run loop. Saves per key coalesce (last write wins), reads see
/// pending writes immediately, and pending writes flush before the app
/// terminates.
public final class FileSystemStore: PersistenceStore, @unchecked Sendable {
  private enum PendingOperation {
    case save(Data)
    case remove
  }

  private let directory: URL
  private let fileManager: FileManager
  /// Serial queue all disk writes run on.
  private let writeQueue = DispatchQueue(label: "com.codevisor.persistence-write", qos: .utility)
  private let pendingLock = NSLock()
  /// Latest not-yet-flushed bytes per key — the coalescing buffer and the
  /// read-your-writes source.
  private var pending: [String: PendingOperation] = [:]
  /// Keys whose failed writes were already surfaced to the user this run,
  /// so a repeatedly failing save logs every time but banners once.
  private var reportedWriteFailures: Set<String> = []
  private var terminationObservers: [any NSObjectProtocol] = []
  /// Called (on the write queue) when a queued disk write fails. When nil,
  /// the failure is surfaced through `ErrorReporter` on the main actor.
  private let onWriteFailure: (@Sendable (String, any Error) -> Void)?

  public init(
    directory: URL? = nil,
    fileManager: FileManager = .default,
    appFolderName: String = CodevisorAppVariant.applicationSupportDirectoryName,
    onWriteFailure: (@Sendable (String, any Error) -> Void)? = nil
  ) {
    self.fileManager = fileManager
    self.onWriteFailure = onWriteFailure
    if let directory {
      self.directory = directory
    } else {
      let base: URL
      do {
        base = try fileManager.url(
          for: .applicationSupportDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true
        )
      } catch {
        base = fileManager.temporaryDirectory
        Log.persistence.fault(
          "Application Support is unavailable; falling back to the temporary directory: \(String(describing: error), privacy: .public)"
        )
        Task { @MainActor in
          ErrorReporter.shared.report(
            .dataDirectoryUnavailable,
            title: "Codevisor Can't Access Its Data Folder",
            message: "Changes made now may not be saved after you quit."
          )
        }
      }
      self.directory = base.appendingPathComponent(appFolderName, isDirectory: true)
    }
    do {
      try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    } catch {
      Log.persistence.error(
        "Failed to create data directory \(self.directory.path, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }

    // Drain queued writes before the process exits so a state change
    // made just before quitting isn't lost. Name-based so this Foundation
    // package needs no AppKit/UIKit import; the store lives for the app's
    // lifetime, so the retained closures are fine.
    //
    // Termination is the one flush that blocks the main thread: the
    // process exits as soon as the notification's handlers return, so the
    // writes must land first.
    #if os(macOS)
      let terminationNotificationName = "NSApplicationWillTerminateNotification"
    #else
      let terminationNotificationName = "UIApplicationWillTerminateNotification"
    #endif
    terminationObservers.append(
      NotificationCenter.default.addObserver(
        forName: Notification.Name(terminationNotificationName),
        object: nil,
        queue: nil
      ) { [weak self] _ in
        self?.flushPendingWrites()
      })
    #if !os(macOS)
      // iOS apps are usually jetsammed from the background without ever
      // seeing a terminate notification, so pending writes also land on
      // backgrounding — but off the main thread, which must keep animating
      // the transition: inside an expiring-activity assertion that keeps
      // the process running until the flush finishes.
      terminationObservers.append(
        NotificationCenter.default.addObserver(
          forName: Notification.Name("UIApplicationDidEnterBackgroundNotification"),
          object: nil,
          queue: nil
        ) { [weak self] _ in
          self?.flushPendingWritesInBackground()
        })
    #endif
  }

  deinit {
    for terminationObserver in terminationObservers {
      NotificationCenter.default.removeObserver(terminationObserver)
    }
    flushPendingWrites()
  }

  private func url(forKey key: String) -> URL {
    directory.appendingPathComponent("\(key).json")
  }

  public func loadData(forKey key: String) -> Data? {
    if let queued = pendingLock.withLock({ pending[key] }) {
      switch queued {
      case let .save(data): return data
      case .remove: return nil
      }
    }
    do {
      return try Data(contentsOf: url(forKey: key))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      // A fresh key with no file yet is the normal empty state.
      return nil
    } catch {
      Log.persistence.error(
        "Failed to read \(key, privacy: .public): \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  public func saveData(_ data: Data, forKey key: String) throws {
    enqueue(.save(data), forKey: key)
  }

  public func removeData(forKey key: String) throws {
    enqueue(.remove, forKey: key)
  }

  private func enqueue(_ operation: PendingOperation, forKey key: String) {
    let alreadyScheduled: Bool = pendingLock.withLock {
      let scheduled = pending[key] != nil
      pending[key] = operation
      return scheduled
    }
    // A write for this key is already queued; it will pick up the newer
    // bytes when it runs.
    guard !alreadyScheduled else { return }
    writeQueue.async { [weak self] in
      guard let self else { return }
      let operation: PendingOperation? = self.pendingLock.withLock {
        let operation = self.pending[key]
        self.pending[key] = nil
        return operation
      }
      guard let operation else { return }
      do {
        try self.applyPendingOperation(operation, forKey: key)
      } catch {
        Log.persistence.error(
          "Failed to write \(key, privacy: .public): \(String(describing: error), privacy: .public)")
        self.notifyWriteFailure(key: key, error: error)
      }
    }
  }

  private func applyPendingOperation(_ operation: PendingOperation, forKey key: String) throws {
    switch operation {
    case let .save(data):
      try data.write(to: self.url(forKey: key), options: .atomic)
    case .remove:
      let url = self.url(forKey: key)
      if self.fileManager.fileExists(atPath: url.path) {
        try self.fileManager.removeItem(at: url)
      }
    }
  }

  /// Surfaces a failed disk write. A custom handler gets every failure; the
  /// default banner fires at most once per key per app run (each occurrence
  /// is still logged above).
  private func notifyWriteFailure(key: String, error: any Error) {
    if let onWriteFailure {
      onWriteFailure(key, error)
      return
    }
    let isFirstForKey = pendingLock.withLock { reportedWriteFailures.insert(key).inserted }
    guard isFirstForKey else { return }
    Task { @MainActor in
      ErrorReporter.shared.report(
        .persistenceWriteFailed,
        title: "Couldn't Save Your Data",
        message:
          "Codevisor couldn't write “\(key)” to its data folder, so recent changes may be lost. Check that your disk isn't full."
      )
    }
  }

  /// Renames the payload file for `key` to `<name>.corrupt-<timestamp>` so
  /// corrupt data survives for diagnosis instead of being overwritten by the
  /// next save.
  public func quarantineCorruptData(forKey key: String) {
    let source = url(forKey: key)
    guard fileManager.fileExists(atPath: source.path) else { return }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let destination = directory.appendingPathComponent(
      "\(source.lastPathComponent).corrupt-\(formatter.string(from: Date()))"
    )
    do {
      try fileManager.moveItem(at: source, to: destination)
      Log.persistence.fault(
        "Quarantined corrupt \(key, privacy: .public) as \(destination.lastPathComponent, privacy: .public)")
    } catch {
      Log.persistence.error(
        "Failed to quarantine corrupt \(key, privacy: .public): \(String(describing: error), privacy: .public)")
    }
  }

  /// Synchronously drains all queued writes. Called on app termination and
  /// available to tests.
  public func flushPendingWrites() {
    // Repository saves encode on a background stage before their bytes
    // reach this store — drain that stage first, so a save issued moments
    // before app termination is durably included in this flush.
    PersistenceEncoding.drain()
    writeQueue.sync {}
  }

  #if !os(macOS)
    /// `flushPendingWrites` without involving the calling thread: the drain
    /// runs on a background thread while ProcessInfo holds an
    /// expiring-activity assertion, so a backgrounding app is not suspended
    /// mid-flush. If the system expires the assertion first, the writes
    /// stay queued and land once the app runs again (or at termination).
    public func flushPendingWritesInBackground() {
      ProcessInfo.processInfo.performExpiringActivity(withReason: "Saving Codevisor data") { [weak self] expired in
        guard !expired else { return }
        self?.flushPendingWrites()
      }
    }
  #endif
}
