import Foundation

@MainActor
final class ScreenSharingHostActivity {
  typealias Token = any NSObjectProtocol

  static let shared = ScreenSharingHostActivity()
  nonisolated static let options: ProcessInfo.ActivityOptions = [.userInitiated, .latencyCritical]
  nonisolated static let reason = "Codevisor is sharing this Mac"

  private let begin: @MainActor () -> Token
  private let end: @MainActor (Token) -> Void
  private var token: Token?
  private var hosting = 0 {
    didSet { hold(hosting > 0) }
  }

  init(
    begin: @escaping @MainActor () -> Token = {
      ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
    },
    end: @escaping @MainActor (Token) -> Void = { ProcessInfo.processInfo.endActivity($0) }
  ) {
    self.begin = begin
    self.end = end
  }

  func claim() -> Claim { Claim(self) }

  private func hold(_ holding: Bool) {
    guard holding != (token != nil) else { return }

    if holding {
      token = begin()
    } else {
      token.map(end)
      token = nil
    }
  }

  @MainActor
  final class Claim {
    private let activity: ScreenSharingHostActivity
    var isHosting = false {
      didSet {
        guard isHosting != oldValue else { return }

        activity.hosting += isHosting ? 1 : -1
      }
    }

    fileprivate init(_ activity: ScreenSharingHostActivity) { self.activity = activity }

    isolated deinit {
      if isHosting { activity.hosting -= 1 }
    }
  }
}
