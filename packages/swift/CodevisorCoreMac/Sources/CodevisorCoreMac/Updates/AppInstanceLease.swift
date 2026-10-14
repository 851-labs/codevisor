import Darwin
import Foundation

@MainActor
public final class AppInstanceLease {
  private let descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    Darwin.close(descriptor)
  }

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

@MainActor
public final class AppUpdateLeaseHandoff {
  private let process: Process

  fileprivate init(process: Process) {
    self.process = process
  }

  public func waitForExit() async {
    let process = process
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        process.waitUntilExit()
        continuation.resume()
      }
    }
  }

  public func cancel() {
    guard process.isRunning else { return }
    process.terminate()
  }
}
