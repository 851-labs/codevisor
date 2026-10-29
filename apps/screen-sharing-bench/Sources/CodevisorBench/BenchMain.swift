import AppKit

@main
@MainActor
enum BenchMain {
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    BenchProcessFiles.recordStart()
    Task {
      let status = await BenchLauncher.run(Array(CommandLine.arguments.dropFirst()))
      BenchProcessFiles.finish(with: status)
    }
    application.run()
  }
}
