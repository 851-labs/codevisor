import CodevisorClient
import Foundation

/// The files this app maintains next to the bundled server's database so an
/// app-hosted server can answer update questions truthfully:
///
/// - The CHANNEL file makes this machine the authority on which release feed
///   it follows. Sparkle installs from this machine's own alpha/stable
///   preference, so the server's update checks must read the same
///   preference — otherwise a remote client's requested channel can make
///   check and install disagree and an "update" never converges.
/// - The STATUS file reports the unattended Sparkle session's progress and
///   outcome, which the server mirrors into `/v1/update` as `lastApply` so
///   a remote client sees "failed: <why>" instead of timing out.
///
/// The app writes; the server only reads. File names must match the
/// server-side constants in `@codevisor/updater`'s app-hosted module.
public enum AppUpdateHandoff {
  public static func defaultChannelURL() -> URL {
    CodevisorAppVariant.serverDataDirectoryURL()
      .appendingPathComponent("app-update-channel")
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

  private struct Status: Encodable {
    let state: String
    let message: String?
    let targetVersion: String?
    let at: String
  }

  /// Reports the unattended update session's state ("installing", or
  /// "failed" with the reason). The server attaches a fresh read of this
  /// file to every update check while it is app-hosted.
  public static func writeStatus(
    state: String,
    message: String? = nil,
    targetVersion: String? = nil,
    at date: Date = Date(),
    to url: URL = defaultStatusURL()
  ) {
    let status = Status(
      state: state,
      message: message,
      targetVersion: targetVersion,
      at: ISO8601DateFormatter().string(from: date)
    )
    guard let payload = try? JSONEncoder().encode(status) else { return }
    try? payload.write(to: url, options: .atomic)
  }

  /// Removes a previous session's report. Called on app launch: a fresh
  /// boot after a successful install must not leave a stale "installing"
  /// (or an old failure) for the server to keep reporting.
  public static func clearStatus(at url: URL = defaultStatusURL()) {
    try? FileManager.default.removeItem(at: url)
  }
}
