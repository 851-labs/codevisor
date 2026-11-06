#if DEBUG
  import CodevisorCore
  import Foundation

  nonisolated enum DemoBots {
    struct Bot {
      let name: String
      let machine: DemoWorld.Machine
      let mascot: ServerBotMascot
      let messages: [Message]
      let age: TimeInterval
      var isUnread = false
      var needsInput = false

      var latestMessage: Message? { messages.last }
    }

    struct Message {
      let sender: ServerBotMessageSender
      let text: String
    }

    private static let idBase = 900
    private static let idsPerBot = 10
    private static let minute: TimeInterval = 60
    private static let hour = 60 * minute

    static let mascotURL = ProcessInfo.processInfo.environment["CODEVISOR_DEMO_MASCOT_URL"].flatMap(URL.init)
    static var isAvailable: Bool { mascotURL != nil }

    static let featured = Bot(
      name: "Scout", machine: DemoWorld.thisMac,
      mascot: ServerBotMascot(color: "sky", hat: "cowboy", eyewear: "shades"),
      messages: [
        Message(sender: .user, text: "Emoji search feels slow on my phone. Can you take a look?"),
        Message(sender: .bot, text: "Found it. We rebuilt the search index on every keystroke."),
        Message(sender: .bot, text: "It's cached now, so a search takes 4\u{00A0}ms instead of 180\u{00A0}ms."),
        Message(sender: .bot, text: "PR #214 is up with a test. Merge it once CI is green?"),
        Message(sender: .user, text: "Yes please, then ship a TestFlight build"),
        Message(sender: .bot, text: "Merged! TestFlight build 318 is on its way."),
      ],
      age: 2 * minute, isUnread: true)

    static let all = [
      featured,
      Bot(
        name: "Pixel", machine: DemoWorld.macStudio,
        mascot: ServerBotMascot(color: "bubblegum", hat: "beret", hatColor: "red", eyewear: "specs"),
        messages: [
          Message(
            sender: .bot, text: "Tightened the spacing on the pricing cards. Before and after shots are in the PR.")
        ],
        age: 14 * minute, isUnread: true),
      Bot(
        name: "Sage", machine: DemoWorld.macStudio,
        mascot: ServerBotMascot(color: "mint", hat: "wizard", hatColor: "purple", eyewear: "monocle"),
        messages: [Message(sender: .bot, text: "Two ways to fix the cache key. Which one do you want?")],
        age: 38 * minute, needsInput: true),
      Bot(
        name: "Bolt", machine: DemoWorld.vps,
        mascot: ServerBotMascot(color: "electric", hat: "hardhat", eyewear: "safety"),
        messages: [Message(sender: .bot, text: "CI is green again. The flaky upload test was racing the cleanup job.")],
        age: 1 * hour),
      Bot(
        name: "Captain", machine: DemoWorld.thisMac,
        mascot: ServerBotMascot(color: "sunny", hat: "sailor", eyewear: "none"),
        messages: [
          Message(sender: .bot, text: "Release notes for 2.4 are drafted. Want a shorter version for the App Store?")
        ],
        age: 3 * hour),
      Bot(
        name: "Chef", machine: DemoWorld.vps,
        mascot: ServerBotMascot(color: "tomato", hat: "chef", eyewear: "none"),
        messages: [Message(sender: .bot, text: "Rotated the TLS certificates on flaco. They're good until March.")],
        age: 5 * hour),
      Bot(
        name: "Nova", machine: DemoWorld.thisMac,
        mascot: ServerBotMascot(color: "lilac", hat: "propeller", eyewear: "anaglyph"),
        messages: [Message(sender: .bot, text: "Your weekly digest: 41% of the 5-hour limit, mostly on tokenmaxxing.")],
        age: 9 * hour),
      Bot(
        name: "Rubber Duck", machine: DemoWorld.macStudio,
        mascot: ServerBotMascot(color: "dream", hat: "duck", eyewear: "none"),
        messages: [Message(sender: .bot, text: "What did you expect that function to return? Walk me through it.")],
        age: 26 * hour),
    ]

    static func on(_ machine: DemoWorld.Machine) -> [Bot] {
      guard isAvailable else { return [] }
      return all.filter { $0.machine.deviceId == machine.deviceId }
    }

    static func botId(_ bot: Bot) -> UUID { id(bot, 0) }
    static func sessionId(_ bot: Bot) -> UUID { id(bot, 1) }
    static func workspaceId(_ bot: Bot) -> UUID { id(bot, 2) }
    static func projectId(_ bot: Bot) -> UUID { id(bot, 3) }
    static func rootPath(_ bot: Bot) -> String { "/Users/you/.codevisor/bots/\(bot.name.lowercased())" }
    static func updatedAt(_ bot: Bot) -> Date { DemoWorld.now.addingTimeInterval(-bot.age) }

    static func today(_ date: Date) -> Date {
      let calendar = Calendar.current
      let time = calendar.dateComponents([.hour, .minute, .second], from: date)
      return calendar.date(
        bySettingHour: time.hour!, minute: time.minute!, second: time.second!, of: Date())!
    }

    static func bot(sessionId: UUID) -> Bot? {
      all.first { self.sessionId($0) == sessionId }
    }

    private static func id(_ bot: Bot, _ offset: Int) -> UUID {
      let index = all.firstIndex { $0.name == bot.name }!
      return DemoModels.id(idBase + index * idsPerBot + offset)
    }
  }
#endif
