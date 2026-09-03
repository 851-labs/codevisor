import Darwin
import Foundation

/// Enforces one running process per exact application bundle and keeps that
/// exclusion alive while an updater replaces the bundle.
///
/// The lock is advisory: every Codevisor process acquires it during AppKit's
/// `applicationWillFinishLaunching`. Before Sparkle asks the current process
/// to quit, a detached helper inherits the locked descriptor. The helper
/// releases it only after the target bundle version is installed, closing the
/// otherwise-unprotected gap between the old process exiting and the new one
/// launching.
@MainActor
public final class AppInstanceLease {
  private let descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    Darwin.close(descriptor)
  }

  /// A stable, per-user lock location scoped to the app's resolved bundle
  /// path. Separate development worktrees may run together; two processes
  /// launched from the same bundle may not.
  public static func defaultLockURL(
    for applicationBundleURL: URL = Bundle.main.bundleURL,
    applicationSupportURL: URL? = nil
  ) -> URL {
    let support =
      applicationSupportURL
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let bundlePath = applicationBundleURL.resolvingSymlinksInPath().standardizedFileURL.path
    return
      support
      .appendingPathComponent("Codevisor/Runtime", isDirectory: true)
      .appendingPathComponent("app-instance-\(stableHash(bundlePath)).lock")
  }

  /// Attempts to own `lockURL`. Returns `nil` when another process (or the
  /// update handoff helper) owns it. `waitFor` is used by the freshly updated
  /// app for the tiny interval between Sparkle launching it and the handoff
  /// helper observing the replaced bundle.
  public static func acquire(
    at lockURL: URL,
    waitFor: TimeInterval = 0
  ) throws -> AppInstanceLease? {
    try FileManager.default.createDirectory(
      at: lockURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let descriptor = lockURL.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else { throw currentPOSIXError() }

    do {
      try validateLockFile(descriptor: descriptor)
      let deadline = Date().addingTimeInterval(max(0, waitFor))
      while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        let code = errno
        guard code == EWOULDBLOCK || code == EAGAIN else {
          throw posixError(code)
        }
        guard Date() < deadline else {
          Darwin.close(descriptor)
          return nil
        }
        Thread.sleep(forTimeInterval: 0.05)
      }
      return AppInstanceLease(descriptor: descriptor)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  public static func acquireDefault(
    for applicationBundleURL: URL = Bundle.main.bundleURL,
    waitFor: TimeInterval = 0
  ) throws -> AppInstanceLease? {
    try acquire(at: defaultLockURL(for: applicationBundleURL), waitFor: waitFor)
  }

  /// Transfers the lease across this process's termination. The shell keeps
  /// the inherited descriptor open while polling the installed Info.plist;
  /// it performs no installation work and exits on success or after a bounded
  /// timeout. The caller must cancel the handoff if Sparkle aborts before quit.
  public func beginUpdateHandoff(
    targetBundleVersion: String,
    applicationBundleURL: URL = Bundle.main.bundleURL,
    timeout: TimeInterval = 300
  ) throws -> AppUpdateLeaseHandoff {
    let infoPlist =
      applicationBundleURL
      .appendingPathComponent("Contents/Info.plist", isDirectory: false)
    let attempts = max(1, Int(ceil(max(0.05, timeout) / 0.05)))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      """
      plist="$1"
      target="$2"
      attempts="$3"
      while [ "$attempts" -gt 0 ]; do
        installed=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null) || installed=
        if [ "$installed" = "$target" ]; then
          exit 0
        fi
        attempts=$((attempts - 1))
        /bin/sleep 0.05
      done
      exit 0
      """,
      "codevisor-update-lease",
      infoPlist.path,
      targetBundleVersion,
      String(attempts),
    ]
    // Process duplicates this descriptor onto the child's stdin. BSD flock
    // ownership follows the open file description, so the lease survives
    // after AppDelegate and the old application process are gone.
    process.standardInput = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return AppUpdateLeaseHandoff(process: process)
  }

  private static func validateLockFile(descriptor: Int32) throws {
    var fileInfo = stat()
    guard Darwin.fstat(descriptor, &fileInfo) == 0 else { throw currentPOSIXError() }
    guard (fileInfo.st_mode & S_IFMT) == S_IFREG, fileInfo.st_uid == geteuid() else {
      throw POSIXError(.EPERM)
    }
    guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
      throw currentPOSIXError()
    }
  }

  private static func stableHash(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }

  private static func currentPOSIXError() -> POSIXError {
    posixError(errno)
  }

  private static func posixError(_ code: Int32) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
  }
}

/// The detached helper retaining an `AppInstanceLease` during a bundle swap.
/// Deinitialization deliberately does not terminate it: successful updates
/// destroy the owning object when the old app exits, which is when the helper
/// is most important.
@MainActor
public final class AppUpdateLeaseHandoff {
  private let process: Process

  fileprivate init(process: Process) {
    self.process = process
  }

  public var isRunning: Bool {
    process.isRunning
  }

  /// Releases the inherited lease when Sparkle aborts while the old app is
  /// still alive.
  public func cancel() {
    guard process.isRunning else { return }
    process.terminate()
  }
}
