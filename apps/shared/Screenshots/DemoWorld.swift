#if DEBUG
  import Foundation

  nonisolated enum DemoWorld {
    struct Machine {
      let deviceId: String
      let name: String
      let os: String
      let icon: String
      let hardware: Hardware

      var serverId: String { "server-\(deviceId)" }
    }

    struct Hardware {
      let chip: String
      let cpuCores: Int
      var gpuCores: Int?
      let memory: Capacity
      let disk: Capacity
      let uptime: TimeInterval
      let cpuLoad: [Double]
      var gpuLoad: [Double]?
    }

    struct Capacity {
      let usedBytes: Double
      let totalBytes: Double
    }

    struct UsageWindow {
      let id: String
      let label: String
      let usedPercent: Double
      let durationMinutes: Double
      let resetsIn: TimeInterval
    }

    struct AttentionNotification {
      let chatTitle: String
      let machine: Machine
      let needsAction: Bool
    }

    struct ContextCategory {
      let name: String
      let tokens: Double
      var isDeferred = false
    }

    struct Project {
      let name: String
      let machine: Machine
      let branch: String
      let chats: [Chat]

      var folderPath: String { "/Users/you/code/\(name)" }
    }

    enum ChatStatus {
      case idle
      case unread
      case inProgress
    }

    struct Chat {
      let title: String
      let harnessId: String
      var status = ChatStatus.idle
    }

    struct Account {
      let email: String
      let isActive: Bool
    }

    struct McpServer {
      let name: String
      let url: String
      let toolCount: Int
      var iconAsset: String?
    }

    struct InstalledAgent {
      let machine: Machine
      let harnessId: String
      let name: String
      let version: String
      var latestVersion: String?
    }

    struct Simulator {
      let udid: String
      let name: String
      let runtime: String
      let runtimeVersion: String
    }

    static let thisMac = Machine(
      deviceId: "this-mac", name: "This Mac", os: "macOS", icon: "laptopcomputer",
      hardware: Hardware(
        chip: "Apple M4 Pro", cpuCores: 14, gpuCores: 20,
        memory: Capacity(usedBytes: 31.4 * gibibyte, totalBytes: 48 * gibibyte),
        disk: Capacity(usedBytes: 612.4e9, totalBytes: 994.66e9), uptime: 4 * day + 6 * hour + 12 * minute,
        cpuLoad: loadHistory(baseline: 9, bursts: [(52..<84, 74), (91..<100, 52)], seed: 1),
        gpuLoad: loadHistory(baseline: 5, bursts: [(70..<77, 22)], seed: 2)))
    static let macStudio = Machine(
      deviceId: "mac-studio", name: "Mac Studio", os: "macOS", icon: "macstudio",
      hardware: Hardware(
        chip: "Apple M3 Ultra", cpuCores: 32, gpuCores: 80,
        memory: Capacity(usedBytes: 96.2 * gibibyte, totalBytes: 256 * gibibyte),
        disk: Capacity(usedBytes: 1.84e12, totalBytes: 3.99e12), uptime: 23 * day + 3 * hour,
        cpuLoad: loadHistory(baseline: 14, bursts: [(30..<60, 58)], seed: 3),
        gpuLoad: loadHistory(baseline: 3, bursts: [], seed: 4)))
    static let vps = Machine(
      deviceId: "vps", name: "VPS", os: "linux", icon: "server.rack",
      hardware: Hardware(
        chip: "AMD EPYC-Milan Processor", cpuCores: 8,
        memory: Capacity(usedBytes: 9.6e9, totalBytes: 16e9),
        disk: Capacity(usedBytes: 141e9, totalBytes: 320e9), uptime: 61 * day + 9 * hour,
        cpuLoad: loadHistory(baseline: 12, bursts: [(80..<88, 35)], seed: 5)))
    static let machines = [thisMac, macStudio, vps]

    static let loadSampleInterval: TimeInterval = 3
    private static let loadSampleCount = 100
    private static let loadWobble = 0.18
    private static let gibibyte = 1_073_741_824.0
    private static let minute: TimeInterval = 60
    private static let hour = 60 * minute
    private static let day = 24 * hour

    private static func loadHistory(baseline: Double, bursts: [(Range<Int>, Double)], seed: Double) -> [Double] {
      (0..<loadSampleCount).map { index in
        let level = bursts.first { $0.0.contains(index) }?.1 ?? baseline
        let wobble = (sin(Double(index) * 12.9898 + seed) * 43_758.5453).truncatingRemainder(dividingBy: 1)
        return max(1, level + wobble * level * loadWobble)
      }
    }

    static let usageWindows = [
      UsageWindow(id: "five-hour", label: "5-hour limit", usedPercent: 41, durationMinutes: 300, resetsIn: 2 * hour),
      UsageWindow(
        id: "seven-day", label: "Weekly limit", usedPercent: 91, durationMinutes: 10_080, resetsIn: 76 * hour),
      UsageWindow(id: "model-0", label: "Weekly Fable", usedPercent: 30, durationMinutes: 10_080, resetsIn: 76 * hour),
    ]

    static let notifications = [
      AttentionNotification(chatTitle: "Add emoji search", machine: thisMac, needsAction: false),
      AttentionNotification(chatTitle: "Wire up the rack view", machine: macStudio, needsAction: true),
    ]

    static let contextWindow = 200_000.0
    static let autocompactBuffer = 33_000.0
    static let featuredContext = [
      ContextCategory(name: "Messages", tokens: 41_300),
      ContextCategory(name: "System tools", tokens: 12_400),
      ContextCategory(name: "System prompt", tokens: 3_100),
      ContextCategory(name: "Memory files", tokens: 2_700),
      ContextCategory(name: "MCP tools", tokens: 1_900),
      ContextCategory(name: "Skills", tokens: 1_200),
      ContextCategory(name: "MCP tools (deferred)", tokens: 21_500, isDeferred: true),
    ]

    static let projects = [
      Project(
        name: "tokenmaxxing", machine: thisMac, branch: "prompt-cache",
        chats: [
          Chat(title: "Cache prompt prefixes between runs", harnessId: "claude-code", status: .inProgress),
          Chat(title: "Chart token spend per model", harnessId: "claude-code"),
        ]),
      Project(
        name: "emojis", machine: thisMac, branch: "skin-tones",
        chats: [
          featuredChat,
          Chat(title: "Fix search for flag emoji", harnessId: "claude-code"),
        ]),
      Project(
        name: "lil.tech", machine: macStudio, branch: "pricing-refresh",
        chats: [
          Chat(title: "Redesign the pricing page", harnessId: "claude-code"),
          Chat(title: "Add an RSS feed to the blog", harnessId: "codex"),
        ]),
      Project(
        name: "MacRack", machine: macStudio, branch: "fan-speeds",
        chats: [
          Chat(title: "Show fan speeds in the menu bar", harnessId: "codex", status: .inProgress),
          Chat(title: "Group machines by rack", harnessId: "claude-code"),
        ]),
      Project(
        name: "flaco", machine: vps, branch: "rate-limits",
        chats: [
          Chat(title: "Add rate limiting to the API", harnessId: "claude-code"),
          Chat(title: "Rotate the TLS certificates", harnessId: "opencode"),
        ]),
    ]

    static let featuredChat = Chat(title: "Add skin tones to the picker", harnessId: "claude-code", status: .unread)
    static var featuredProject: Project { projects.first { $0.name == "emojis" }! }
    static let featuredModel = (id: "claude-sonnet-4-6", name: "Sonnet 4.6")
    static let previewURL = "http://localhost:3000"

    static let accounts = [
      Account(email: "alexandru@emojis.com", isActive: true),
      Account(email: "pondorasti@gmail.com", isActive: false),
    ]

    static let mcpServers = [
      McpServer(name: "Linear", url: "https://mcp.linear.app/mcp", toolCount: 12, iconAsset: "linear.png"),
      McpServer(name: "Notion", url: "https://mcp.notion.com/mcp", toolCount: 15, iconAsset: "notion.png"),
      McpServer(name: "Sentry", url: "https://mcp.sentry.dev/mcp", toolCount: 18),
    ]

    static let appVersion = "0.1.107"
    static let latestAppVersion = "0.1.108"
    static let machinesWithServerUpdate = [macStudio.deviceId, vps.deviceId]
    static let installedAgents = [
      InstalledAgent(
        machine: thisMac, harnessId: "claude-code", name: "Claude Code", version: "2.1.4", latestVersion: "2.1.6"),
      InstalledAgent(machine: thisMac, harnessId: "codex", name: "Codex", version: "0.40.0", latestVersion: "0.41.0"),
      InstalledAgent(machine: macStudio, harnessId: "claude-code", name: "Claude Code", version: "2.1.6"),
      InstalledAgent(machine: macStudio, harnessId: "codex", name: "Codex", version: "0.40.0", latestVersion: "0.41.0"),
      InstalledAgent(machine: vps, harnessId: "claude-code", name: "Claude Code", version: "2.1.6"),
      InstalledAgent(machine: vps, harnessId: "opencode", name: "OpenCode", version: "2.0.23", latestVersion: "2.0.24"),
    ]

    static var harnessesOnEveryMachine: [InstalledAgent] {
      Dictionary(grouping: installedAgents, by: \.harnessId).values
        .filter { $0.count == machines.count }
        .compactMap(\.first)
        .sorted { $0.name < $1.name }
    }

    static let simulator = Simulator(
      udid: "00000000-0000-0000-0000-000000000017", name: "iPhone 17 Pro", runtime: "iOS 26.1", runtimeVersion: "26.1")

    static let now = Calendar.current.date(
      from: DateComponents(year: 2001, month: 8, day: 8, hour: 14, minute: 5))!
    static let statusBarTime = "2001-08-08T14:05:00"

    static let chatFinishedSoundPath = "/System/Library/Sounds/Glass.aiff"
    static let actionRequiredSoundPath = "/System/Library/Sounds/Hero.aiff"

    static func assetData(_ name: String) -> Data? {
      repoFile("apps/shared/DemoWorldAssets/\(name)").flatMap { try? Data(contentsOf: $0) }
    }

    static func repoFile(_ path: String) -> URL? {
      ProcessInfo.processInfo.environment["CODEVISOR_DEMO_REPO"].map {
        URL(fileURLWithPath: $0).appendingPathComponent(path)
      }
    }
  }
#endif
