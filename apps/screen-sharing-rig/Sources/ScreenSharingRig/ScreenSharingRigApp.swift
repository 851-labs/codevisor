#if os(macOS)
  import AppKit
  import CodevisorScreenSharing
  import Foundation
  import ScreenSharingRigKit

  /// `screen-sharing-rig --config rig.json`: the resident host or viewer
  /// process. A consumer of the media package, not part of it; see
  /// docs/plans/screen-sharing-rig.md.
  @main
  @MainActor
  struct ScreenSharingRigApp {
    static func main() {
      do {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, arguments[0] == "--config" else {
          throw ScreenSharingError.invalid("Usage: screen-sharing-rig --config /path/to/rig.json")
        }
        let path = (arguments[1] as NSString).expandingTildeInPath
        let configuration = try RigConfiguration.parse(try Data(contentsOf: URL(fileURLWithPath: path)))
        // Process-global trials from rig.json's tuning; a change means a fresh process, which `rig tune` does.
        _ = try ScreenSharingFieldTrials.process.install(configuration.tuning.fieldTrialSelection)
        let app = NSApplication.shared
        app.setActivationPolicy(configuration.role == .viewer ? .regular : .accessory)
        let runner = RigRunner(
          configuration: configuration, build: RigBuildInfo(infoDictionary: Bundle.main.infoDictionary))
        Task { @MainActor in
          do { try await runner.run() } catch {
            await runner.stop()
            FileHandle.standardError.write(Data("Screen Sharing rig: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
          }
        }
        withExtendedLifetime(runner) { app.run() }
      } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
      }
    }
  }
#else
  @main
  struct ScreenSharingRigApp {
    static func main() { print("The Screen Sharing rig requires macOS.") }
  }
#endif
