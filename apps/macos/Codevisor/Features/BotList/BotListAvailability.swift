import CodevisorCore

struct BotListAvailability {
  let environment: AppEnvironment

  var hasBots: Bool {
    !environment.bots.bots.isEmpty
  }

  var hasLoaded: Bool {
    environment.navigationLaunch(hasVisibleContent: false) != .loading
  }
}
