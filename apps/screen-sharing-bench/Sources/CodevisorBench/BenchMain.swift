import AppKit

@main
@MainActor
enum BenchMain {
  static func main() {
    let application = NSApplication.shared
    let launch = BenchLauncher.prepare(Array(CommandLine.arguments.dropFirst()))
    application.setActivationPolicy(launch.presentsWindows ? .regular : .prohibited)
    BenchProcessFiles.recordStart()
    Task {
      let status = await BenchLauncher.run(launch)
      BenchProcessFiles.finish(with: status)
    }
    application.run()
  }
}
