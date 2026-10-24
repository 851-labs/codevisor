#if DEBUG
  import AppKit
  import CodevisorCore

  enum BentoRender {
    static var outputDirectory: URL? {
      ProcessInfo.processInfo.environment["CODEVISOR_BENTO_RENDER"].map { URL(fileURLWithPath: $0) }
    }

    private static var selectedCards: Set<String>? {
      ProcessInfo.processInfo.environment["CODEVISOR_BENTO_CARDS"]
        .map { Set($0.split(separator: ",").map(String.init)) }
    }

    @MainActor
    static func run(into directory: URL) -> Never {
      let application = NSApplication.shared
      application.setActivationPolicy(.accessory)
      let frontmost = NSWorkspace.shared.frontmostApplication
      activateSoControlsDrawActive(application)
      Task {
        var status: Int32 = 0
        do {
          try await renderCards(into: directory)
        } catch {
          FileHandle.standardError.write(Data("Bento render failed: \(error)\n".utf8))
          status = 1
        }
        frontmost?.activate()
        exit(status)
      }
      application.run()
      exit(0)
    }

    @MainActor
    private static func activateSoControlsDrawActive(_ application: NSApplication) {
      application.activate(ignoringOtherApps: true)
    }

    @MainActor
    private static func renderCards(into directory: URL) async throws {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let cards = BentoCard.all.filter { selectedCards?.contains($0.name) ?? true }
      for card in cards {
        let environment = DemoEnvironment.make()
        card.prepare(environment)
        await DemoEnvironment.connect(environment)
        for appearance in BentoAppearance.allCases {
          let file = directory.appendingPathComponent("\(card.name)-\(appearance.rawValue)@2x.png")
          try await BentoCapture(card: card, appearance: appearance, environment: environment).write(to: file)
          print(file.path)
        }
      }
      BentoLocalShell.closeAll()
    }
  }

  enum BentoAppearance: String, CaseIterable {
    case light
    case dark

    var name: NSAppearance.Name { self == .dark ? .darkAqua : .aqua }
  }
#endif
