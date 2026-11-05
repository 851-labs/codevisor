import CodevisorCore
import Observation

@MainActor
@Observable
public final class BotMascotActivitySource {
  public static let shared = BotMascotActivitySource()

  private var reader: @MainActor (Bot) -> BotMascotActivity = { _ in .resting }

  public func read(with reader: @escaping @MainActor (Bot) -> BotMascotActivity) {
    self.reader = reader
  }

  func activity(of bot: Bot) -> BotMascotActivity {
    reader(bot)
  }
}
