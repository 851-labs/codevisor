import Foundation
import notify

final class DarwinNotificationObserver {
  private var token: Int32 = NOTIFY_TOKEN_INVALID

  init(_ name: String, handler: @escaping @MainActor () -> Void) {
    notify_register_dispatch(name, &token, .main) { _ in
      MainActor.assumeIsolated { handler() }
    }
  }

  deinit {
    if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
  }
}
