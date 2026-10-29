import AppKit
import Darwin
import ScreenSharingBench

@MainActor
struct PreflightReport: Encodable {
  static let virtualDisplayName = "Screen Sharing Virtual Display"
  private static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

  let machine = BenchHostName.current
  let chip = MachineModel.chip
  let os = ProcessInfo.processInfo.operatingSystemVersionString
  let load1: Double
  let thermal: String
  let ciJobs: Int
  let locked: Bool
  let mainDisplay: String?
  let mainDisplayName: String?
  let displays: [String]
  let screenSharingPeers: [String]
  let quiet: QuietMachine?
  let problems: [String]

  init(allowedPeers: Set<String>, peers: [String], allowsLocked: Bool = false, quiet: QuietMachine? = nil) {
    load1 = Self.loadAverage()
    thermal = Self.thermalState()
    ciJobs = BenchProcesses.pids(named: "Runner.Worker").count
    locked = (try? PlayerConsoleSession.requireUnlocked()) == nil
    mainDisplay = Self.mainScreen().map(Self.describe)
    mainDisplayName = Self.mainScreen()?.localizedName
    displays = NSScreen.screens.map(Self.describe)
    screenSharingPeers = peers
    self.quiet = quiet
    problems =
      Self.problems(
        locked: locked && !allowsLocked, mainDisplay: mainDisplayName, peers: peers, allowed: allowedPeers)
      + Self.quietProblems(quiet, thermal: thermal)
  }

  private static func problems(locked: Bool, mainDisplay: String?, peers: [String], allowed: Set<String>) -> [String] {
    var problems: [String] = []
    if locked { problems.append("the GUI session is locked") }
    let strangers = peers.filter { !allowed.contains($0) }
    if !strangers.isEmpty { problems.append("someone is screen sharing into this Mac from \(strangers)") }
    let ours = peers.contains(where: allowed.contains)
    if mainDisplay == virtualDisplayName, !ours { problems.append("the main display is \(virtualDisplayName)") }
    return problems
  }

  private static func quietProblems(_ quiet: QuietMachine?, thermal: String) -> [String] {
    guard let quiet else { return [] }

    return quiet.problems + (thermal == "nominal" ? [] : ["the thermal state is \(thermal)"])
  }

  private static func describe(_ screen: NSScreen) -> String {
    let id = screen.deviceDescription[screenNumberKey] as? CGDirectDisplayID ?? 0
    let hz = CGDisplayCopyDisplayMode(id).map { Int($0.refreshRate.rounded()) } ?? 0
    let size = "\(Int(screen.frame.width))x\(Int(screen.frame.height))@\(hz) \(Int(screen.backingScaleFactor))x"
    return screen.localizedName.isEmpty ? size : "\(size) \(screen.localizedName)"
  }

  private static func mainScreen() -> NSScreen? {
    NSScreen.screens.first { $0.deviceDescription[screenNumberKey] as? CGDirectDisplayID == CGMainDisplayID() }
  }

  private static func loadAverage() -> Double {
    var loads = [Double](repeating: 0, count: 1)
    return getloadavg(&loads, 1) == 1 ? loads[0] : -1
  }

  private static func thermalState() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }
}
