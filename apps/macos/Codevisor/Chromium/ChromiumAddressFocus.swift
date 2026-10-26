import Observation

@MainActor
@Observable
final class ChromiumAddressFocus {
  private(set) var request = 0
  @ObservationIgnored private var pending = false
  @ObservationIgnored var isEditing = false

  var keepsFocus: Bool { pending || isEditing }

  func focus() {
    request += 1
    pending = true
  }

  func takeRequest() -> Bool {
    defer { pending = false }
    return pending
  }
}
