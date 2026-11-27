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
    let preferred = withObservationTracking {
      connection.preferredDisplayId
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.watch() }
    }
    saveIfAdopted(preferred)
  }

  private func saveIfAdopted(_ preferred: String?) {
    guard let chosen, chosen == preferred else { return }

    self.chosen = nil
    save(chosen)
  }
}
