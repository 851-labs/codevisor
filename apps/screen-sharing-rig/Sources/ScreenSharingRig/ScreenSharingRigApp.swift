#if os(macOS)
  import AppKit
  import ScreenSharing
  import ScreenSharingWebRTC
  import Foundation
  import ScreenSharingRigKit

  /// `screen-sharing-rig` alone opens the scenario window (`RigShell`).
  /// `screen-sharing-rig --config rig.json`: the resident host or viewer
  /// process; the viewer opens the same window on its Native session scenario.
  /// `screen-sharing-rig probe …`: the single-process diagnostic (see
  /// `ProbeCommand`). `screen-sharing-rig vnc-server …`: a loopback VNC server
  /// for the VNC viewer (see `VNCServerCommand`). `screen-sharing-rig
  /// vnc-bench …`: the VNC benchmark (see `VNCBenchCommand`). A consumer of the media
  /// package, not part of it; see docs/plans/screen-sharing-rig.md.
  @main
  @MainActor
  struct ScreenSharingRigApp {
    static func main() {
      do {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "probe" {
          ProbeCommand.main(arguments: Array(arguments.dropFirst()))
          return
        }
        if arguments.first == "vnc-record" {
          VNCRecordCommand.main(arguments: Array(arguments.dropFirst()))
          return
        }
        if arguments.first == "vnc-keys" {
          VNCKeysCommand.main(arguments: Array(arguments.dropFirst()))
          return
        }
        if arguments.first == "vnc-sample" {
          VNCSampleCommand.main(arguments: Array(arguments.dropFirst()))
          return
        }
        if arguments.first == "vnc-bench" {
          VNCBenchCommand.main(arguments: Array(arguments.dropFirst()))
          return
        }
        if arguments.first == "vnc-server" {
          VNCServerCommand.main(arguments: Array(arguments.dropFirst()))
          return
        }
        if arguments.isEmpty { RigShell.run() }
        guard arguments.count == 2, arguments[0] == "--config" else {
          throw ScreenSharingError.invalid(
            "Usage: screen-sharing-rig --config /path/to/rig.json | screen-sharing-rig probe [--help] | screen-sharing-rig vnc-server [--help]"
          )
        }
        let path = (arguments[1] as NSString).expandingTildeInPath
        let configuration = try RigConfiguration.parse(try Data(contentsOf: URL(fileURLWithPath: path)))
        // Process-global trials from rig.json's tuning; a change means a fresh process, which `rig tune` does.
        _ = try ScreenSharingFieldTrials.process.install(configuration.tuning.fieldTrialSelection)
        let runner = RigRunner(
          configuration: configuration, build: RigBuildInfo(infoDictionary: Bundle.main.infoDictionary))
        Task { @MainActor in
          do { try await runner.run() } catch {
            await runner.stop()
            FileHandle.standardError.write(Data("Screen Sharing rig: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
          }
        }
        switch configuration.role {
        case .viewer: RigShell.run(runner: runner)
        case .host:
          let app = NSApplication.shared
          app.setActivationPolicy(.accessory)
          withExtendedLifetime(runner) { app.run() }
        }
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
