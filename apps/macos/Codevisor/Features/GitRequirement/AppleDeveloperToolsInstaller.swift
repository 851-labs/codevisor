import Foundation

nonisolated enum AppleDeveloperToolsInstaller {
  @concurrent
  static func open() async -> String? {
    let process = Process()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["--install"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    do {
      try process.run()
    } catch {
      return error.localizedDescription
    }
    process.waitUntilExit()
    guard process.terminationStatus != 0 else { return nil }

    return failure(from: String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self))
  }

  private static func failure(from message: String) -> String {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Apple's installer didn't open." : trimmed
  }
}
