#if DEBUG
  import AppKit
  import CodevisorClient
  import ImageIO
  import ScreenSharing
  import SimulatorPane
  import SwiftUI

  struct BentoSimulatorPane: View {
    @State private var model = BentoSimulator.model()

    var body: some View {
      if let model {
        SimulatorPaneView(model: model)
          .toolbar(removing: .title)
          .toolbar { SimulatorPaneToolbar(model: model) { _, _ in } }
          .task {
            try? await Task.sleep(for: BentoSimulator.listSettle)
            model.showsSettings = true
            await model.loadSettings()
          }
      } else {
        ContentUnavailableView("No simulator fixture", systemImage: "iphone")
      }
    }
  }

  enum BentoSimulator {
    struct Fixture: Decodable {
      let udid: String
      let list: ServerSimulatorList
      let deviceTypes: [String: ServerSimulatorDeviceTypeDetail]
      let settings: [String: ServerSimulatorSettings]
      let screens: [String: String]
    }

    static let listSettle = Duration.seconds(1)

    @MainActor
    static func model() -> SimulatorPaneModel? {
      guard let path = ProcessInfo.processInfo.environment["CODEVISOR_BENTO_SIMULATOR_FIXTURE"],
        let data = FileManager.default.contents(atPath: path),
        let fixture = try? JSONDecoder().decode(Fixture.self, from: data)
      else { return nil }
      let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
      let screen = fixture.screens[appearance].flatMap(image(atPath:))
      guard let settings = fixture.settings[appearance] else { return nil }
      return SimulatorPaneModel.preview(
        client: Client(fixture: fixture, settings: settings, chromes: chromes(in: data)), udid: fixture.udid,
        connection: Connection(screen: screen))
    }

    private static func chromes(in data: Data) -> [String: ServerSimulatorChrome] {
      guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let chromes = object["chromes"] as? [String: [String: Any]]
      else { return [:] }
      return chromes.reduce(into: [:]) { result, entry in
        guard let definition = entry.value["definition"],
          let images = entry.value["images"] as? [String: String],
          let encoded = try? JSONSerialization.data(withJSONObject: definition)
        else { return }
        result[entry.key] = ServerSimulatorChrome(identifier: entry.key, definition: encoded, images: images)
      }
    }

    private static func image(atPath path: String) -> CGImage? {
      guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
      return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private struct Client: SimulatorClienting {
      let fixture: Fixture
      let settings: ServerSimulatorSettings
      let chromes: [String: ServerSimulatorChrome]

      func simulators() async throws -> ServerSimulatorList { fixture.list }

      func simulatorDeviceType(identifier: String) async throws -> ServerSimulatorDeviceTypeDetail {
        guard let detail = fixture.deviceTypes[identifier] else { throw CocoaError(.fileNoSuchFile) }
        return detail
      }

      func simulatorChrome(identifier: String) async throws -> ServerSimulatorChrome {
        guard let chrome = chromes[identifier] else { throw CocoaError(.fileNoSuchFile) }
        return chrome
      }

      func simulatorSettings(udid: String) async throws -> ServerSimulatorSettings { settings }

      func changeSimulatorSettings(_ change: ServerSimulatorSettingsChange) async throws -> ServerSimulatorSettings {
        settings
      }

      func performSimulatorAction(_ action: ServerSimulatorAction, udid: String) async throws {}

      func createSimulator(
        name: String, deviceTypeIdentifier: String, runtimeIdentifier: String
      ) async throws
        -> String
      { throw CocoaError(.featureUnsupported) }

      func renameSimulator(udid: String, name: String) async throws {}

      func simulatorScreenshot(udid: String) async throws -> Data { throw CocoaError(.featureUnsupported) }
    }

    @MainActor
    private final class Connection: SimulatorConnection {
      let phase = SimulatorConnectionPhase.streaming
      let state: ScreenSharingSimulatorState? = ScreenSharingSimulatorState(orientation: .portrait)
      let source: SimulatorScreenSource?
      let frameSize: CGSize?

      init(screen: CGImage?) {
        source = .image(screen)
        frameSize = screen.map { CGSize(width: $0.width, height: $0.height) }
      }

      func start() {}
      func stop() {}
      func send(_ message: ScreenSharingSimulatorMessage) -> Bool { false }
      func presented(frameSize: CGSize) {}
    }
  }
#endif
