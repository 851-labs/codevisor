import ScreenSharingBench

enum Tier2InputRun {
  private static let screenSharingApp = "com.apple.ScreenSharing"
  private static let benchApp = "com.851labs.CodevisorBench"

  static func toPhoton(_ files: Tier2RunFiles) -> BenchInputToPhoton? {
    guard files.meta.isInput, let events = files.inputEvents else { return nil }

    return BenchInputToPhoton(events: events, observations: files.viewer)
  }

  static func invalidReason(_ files: Tier2RunFiles, _ toPhoton: BenchInputToPhoton?) -> String? {
    guard files.meta.isInput else { return nil }
    guard let toPhoton, toPhoton.events > 0 else { return "no input events were posted" }
    if let app = otherFrontmostApp(files) { return "\(app) was frontmost during some input events" }
    if let reason = controlProblem(files) { return reason }
    guard toPhoton.answered != nil else { return "no input event changed the viewer's picture" }

    return nil
  }

  private static func otherFrontmostApp(_ files: Tier2RunFiles) -> String? {
    guard case .array(let apps)? = files.inject?["frontmost"] else { return "no app" }

    let expected = files.meta.system == .appleHP ? screenSharingApp : benchApp
    return apps.compactMap { $0["app"]?.string }.first { $0 != expected }
  }

  private static func controlProblem(_ files: Tier2RunFiles) -> String? {
    switch files.meta.system {
    case .appleHP: appleControlProblem(files.system)
    case .codevisor, .codevisorV2: codevisorControlProblem(files.system)
    case .floor: nil
    }
  }

  private static func appleControlProblem(_ system: [String: JSONValue]?) -> String? {
    let modes = [system?["control_mode"]?.string, system?["mode_at_end"]?.string]
    guard !modes.contains("observe") else { return "Screen Sharing was in Observe mode" }

    return nil
  }

  private static func codevisorControlProblem(_ system: [String: JSONValue]?) -> String? {
    guard system?["control"]?["granted"]?.bool == true else { return "Codevisor never held the control lease" }
    guard case .array(let losses)? = system?["control"]?["losses"], let loss = losses.first?.string else { return nil }

    return "the control lease was lost: \(loss)"
  }
}
