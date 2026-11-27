import Observation
import ScreenSharingConnection

@MainActor
final class ScreenSharingChosenDisplay {
  private let connection: ScreenSharingConnection
  private let save: (String) -> Void
  private var chosen: String?

  init(connection: ScreenSharingConnection, save: @escaping (String) -> Void) {
    self.connection = connection
    self.save = save
    watch()
  }

  func choose(_ displayId: String) {
    chosen = displayId
    saveIfAdopted(connection.preferredDisplayId)
  }

  private func watch() {
    let (preferred, result) = withObservationTracking {
      (connection.preferredDisplayId, connection.displaySwitch)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.watch() }
    }
    forgetIfRefused(result)
    saveIfAdopted(preferred)
  }

  private func forgetIfRefused(_ result: ScreenSharingDisplaySwitch?) {
    guard let result, result.displayId == chosen, result.failure != nil else { return }

    chosen = nil
  }

  private func saveIfAdopted(_ preferred: String?) {
    guard let chosen, chosen == preferred else { return }

    self.chosen = nil
    save(chosen)
  }
}
