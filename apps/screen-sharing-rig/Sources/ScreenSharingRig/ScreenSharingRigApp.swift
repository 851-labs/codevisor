#if os(macOS)
  import AppKit
  import ScreenSharing
  import ScreenSharingWebRTC
  import Foundation
  import ScreenSharingRigKit

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
        if arguments.first == "frame-clock" {
          FrameClockCommand.main(arguments: Array(arguments.dropFirst()))
          return
        }
        if arguments.first == "colour-check" {
          ColourCheckCommand.main(arguments: Array(arguments.dropFirst()))
          return
        }
        if arguments.first == "mirror-check" {
          MirrorCheckCommand.main(arguments: Array(arguments.dropFirst()))
          return
        }
        if arguments.first == "vnc-server" {
          VNCServerCommand.main(arguments: Array(arguments.dropFirst()))
          return
        }
        if arguments.isEmpty {
          installPlayoutOverride()
          RigShell.run()
        }
        guard arguments.count == 2, arguments[0] == "--config" else {
          throw ScreenSharingError.invalid(
            "Usage: screen-sharing-rig --config /path/to/rig.json | screen-sharing-rig probe [--help] | screen-sharing-rig vnc-server [--help]"
          )
        }
        let path = (arguments[1] as NSString).expandingTildeInPath
        let configuration = try RigConfiguration.parse(try Data(contentsOf: URL(fileURLWithPath: path)))
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
