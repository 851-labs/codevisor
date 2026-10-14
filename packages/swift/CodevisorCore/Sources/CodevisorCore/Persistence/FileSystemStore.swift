import Foundation

public final class FileSystemStore: PersistenceStore, @unchecked Sendable {
  private enum PendingOperation {
    case save(Data)
    case remove
  }

  private let directory: URL
  private let fileManager: FileManager
  private let writeQueue = DispatchQueue(label: "com.codevisor.persistence-write", qos: .utility)
  private let pendingLock = NSLock()
  private var pending: [String: PendingOperation] = [:]
  private var reportedWriteFailures: Set<String> = []
  private var terminationObservers: [any NSObjectProtocol] = []
  private let onWriteFailure: (@Sendable (String, any Error) -> Void)?

  public init(
    directory: URL? = nil,
    fileManager: FileManager = .default,
    appFolderName: String = CodevisorAppVariant.applicationSupportDirectoryName,
    onWriteFailure: (@Sendable (String, any Error) -> Void)? = nil
  ) {
    self.fileManager = fileManager
    self.onWriteFailure = onWriteFailure
    self.directory = Self.resolveDirectory(
      directory: directory, fileManager: fileManager, appFolderName: appFolderName
    )
    do {
      try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    } catch {
      Log.persistence.error(
        "Failed to create data directory \(self.directory.path, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }

    registerTerminationObserver()
    #if !os(macOS)
      registerBackgroundObserver()
    #endif
  }

  private static func resolveDirectory(
    directory: URL?, fileManager: FileManager, appFolderName: String
  ) -> URL {
    if let directory {
      return directory
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
      return base.appendingPathComponent(appFolderName, isDirectory: true)
    }
  }

  private func registerTerminationObserver() {
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
  }

  #if !os(macOS)
    private func registerBackgroundObserver() {
      terminationObservers.append(
        NotificationCenter.default.addObserver(
          forName: Notification.Name("UIApplicationDidEnterBackgroundNotification"),
          object: nil,
          queue: nil
        ) { [weak self] _ in
          self?.flushPendingWritesInBackground()
        })
    }
  #endif

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

  public func flushPendingWrites() {
    PersistenceEncoding.drain()
    writeQueue.sync {}
  }

  #if !os(macOS)
    public func flushPendingWritesInBackground() {
      ProcessInfo.processInfo.performExpiringActivity(withReason: "Saving Codevisor data") { [weak self] expired in
        guard !expired else { return }
        self?.flushPendingWrites()
      }
    }
  #endif
}
