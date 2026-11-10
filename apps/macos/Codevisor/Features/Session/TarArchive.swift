import Foundation

nonisolated enum TarArchive {
  struct ExtractionFailed: LocalizedError {
    let message: String

    var errorDescription: String? { "Couldn't unpack the folder: \(message)" }
  }

  static func extract(_ archive: URL, into directory: URL) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-x", "-f", archive.path, "-C", directory.path]
    let errors = Pipe()
    process.standardError = errors

    try await run(process)

    guard process.terminationStatus != 0 else { return }
    let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    throw ExtractionFailed(message: message.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func run(_ process: Process) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      process.terminationHandler = { _ in continuation.resume() }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
  }
}
