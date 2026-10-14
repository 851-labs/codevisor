import CodevisorClient
import CodevisorCore
import Foundation

public enum AppUpdateHandoff {
  public static func defaultChannelURL() -> URL {
    CodevisorAppVariant.serverDataDirectoryURL()
      .appendingPathComponent("app-update-channel")
  }

  public static func defaultFeedURL() -> URL {
    CodevisorAppVariant.serverDataDirectoryURL()
      .appendingPathComponent("app-update-feed")
  }

  public static func defaultStatusURL() -> URL {
    CodevisorAppVariant.serverDataDirectoryURL()
      .appendingPathComponent("app-update-status.json")
  }

  public static func writeChannel(allowsAlpha: Bool, to url: URL = defaultChannelURL()) {
    try? Data("\(allowsAlpha ? "alpha" : "stable")\n".utf8).write(to: url, options: .atomic)
  }

  public static func writeFeedURL(_ feedURL: String, to url: URL = defaultFeedURL()) {
    try? Data("\(feedURL)\n".utf8).write(to: url, options: .atomic)
  }

  private struct Status: Encodable {
    let progress: Double?
    let state: String
    let message: String?
    let targetVersion: String?
    let targetBuildNumber: Int?
    let at: String
  }

  public static func writeStatus(
    state: String,
    message: String? = nil,
    targetVersion: String? = nil,
    targetBuildNumber: Int? = nil,
    progress: Double? = nil,
    at date: Date = Date(),
    to url: URL = defaultStatusURL()
  ) {
    let status = Status(
      progress: progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil },
      state: state,
      message: message,
      targetVersion: targetVersion,
      targetBuildNumber: targetBuildNumber,
      at: date.formatted(timestampStyle)
    )
    guard let payload = try? JSONEncoder().encode(status) else { return }
    try? payload.write(to: url, options: .atomic)
  }

  private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  static let writes = CoalescingWorkQueue(label: "com.codevisor.app-update-handoff")

  public static func enqueueStatus(
    state: String,
    message: String? = nil,
    targetVersion: String? = nil,
    targetBuildNumber: Int? = nil,
    progress: Double? = nil,
    to url: URL = defaultStatusURL()
  ) {
    let date = Date()
    writes.enqueue(key: url.path) {
      writeStatus(
        state: state, message: message, targetVersion: targetVersion,
        targetBuildNumber: targetBuildNumber, progress: progress, at: date, to: url)
    }
  }

  public static func enqueueClearStatus(at url: URL = defaultStatusURL()) {
    writes.enqueue(key: url.path) { clearStatus(at: url) }
  }

  public static func enqueueChannel(allowsAlpha: Bool, to url: URL = defaultChannelURL()) {
    writes.enqueue(key: url.path) { writeChannel(allowsAlpha: allowsAlpha, to: url) }
  }

  public static func enqueueFeedURL(_ feedURL: String, to url: URL = defaultFeedURL()) {
    writes.enqueue(key: url.path) { writeFeedURL(feedURL, to: url) }
  }

  public static func flushWrites() async {
    await writes.flush()
  }

  public static func clearStatus(at url: URL = defaultStatusURL()) {
    try? FileManager.default.removeItem(at: url)
  }
}
