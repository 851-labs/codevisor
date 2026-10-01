import CodevisorClient
import CodevisorCore
import Foundation

/// The files this app maintains next to the bundled server's database so an
/// app-hosted server can answer update questions truthfully:
///
/// - The CHANNEL file makes this machine the authority on which release feed
///   it follows. Sparkle installs from this machine's own alpha/stable
///   preference, so the server's update checks must read the same
///   preference — otherwise a remote client's requested channel can make
///   check and install disagree and an "update" never converges.
/// - The FEED file is the exact appcast URL Sparkle installs from. The
///   server reads "latest" from that same document, so what it reports and
///   what Sparkle installs can no longer disagree.
/// - The STATUS file reports the unattended Sparkle session's progress and
///   outcome, which the server mirrors into `/v1/update` as `lastApply` so
///   a remote client sees "failed: <why>" instead of timing out — and the
///   build Sparkle is actually installing, which may be older than the
///   feed's newest when Sparkle resumes an earlier download.
///
/// The app writes; the server only reads. File names must match the
/// server-side constants in `@codevisor/updater`'s app-hosted module.
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

  /// Records which release feed this machine follows. Called at startup
  /// and whenever the user flips the Alpha-updates preference.
  public static func writeChannel(allowsAlpha: Bool, to url: URL = defaultChannelURL()) {
    try? Data("\(allowsAlpha ? "alpha" : "stable")\n".utf8).write(to: url, options: .atomic)
  }

  /// Records the appcast Sparkle resolves updates from. Called at startup
  /// (the feed is fixed per build; only development runs override it).
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

  /// Reports the unattended update session's state ("installing", or
  /// "failed" with the reason). The server attaches a fresh read of this
  /// file to every update check while it is app-hosted.
  ///
  /// Synchronous: encodes and writes on the calling thread. The app calls
  /// `enqueueStatus` instead, which runs this on `writes`.
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

  /// Created once: a formatter per status report was measurable while
  /// Sparkle reported every downloaded chunk.
  private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  /// The app's handoff writes, off the main thread. Sparkle reports from
  /// main-thread callbacks; each report replaces the previous one still
  /// waiting for the disk, and because the queue is serial the newest state
  /// (a failure, the final "Restarting…") is always the one left on disk.
  static let writes = CoalescingWorkQueue(label: "com.codevisor.app-update-handoff")

  /// `writeStatus` on the handoff queue. The timestamp is taken now, when
  /// the state changed, not when the write runs.
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

  /// `clearStatus` on the handoff queue, ordered with status writes to the
  /// same file.
  public static func enqueueClearStatus(at url: URL = defaultStatusURL()) {
    writes.enqueue(key: url.path) { clearStatus(at: url) }
  }

  /// `writeChannel` on the handoff queue.
  public static func enqueueChannel(allowsAlpha: Bool, to url: URL = defaultChannelURL()) {
    writes.enqueue(key: url.path) { writeChannel(allowsAlpha: allowsAlpha, to: url) }
  }

  /// `writeFeedURL` on the handoff queue.
  public static func enqueueFeedURL(_ feedURL: String, to url: URL = defaultFeedURL()) {
    writes.enqueue(key: url.path) { writeFeedURL(feedURL, to: url) }
  }

  /// Suspends until every handoff write enqueued so far is on disk. Called
  /// before Sparkle relaunches the app, so the server reads the last state.
  public static func flushWrites() async {
    await writes.flush()
  }

  /// Removes a previous session's report. Called on app launch: a fresh
  /// boot after a successful install must not leave a stale "installing"
  /// (or an old failure) for the server to keep reporting.
  public static func clearStatus(at url: URL = defaultStatusURL()) {
    try? FileManager.default.removeItem(at: url)
  }
}
