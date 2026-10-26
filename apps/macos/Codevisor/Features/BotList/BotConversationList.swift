import CodevisorCore

struct BotConversationList {
  let environment: AppEnvironment
  let store: SessionStore?

  func conversations() -> [BotConversation] {
    environment.bots.bots
      .map(conversation(for:))
      .sorted(by: BotConversation.byRecency)
  }

  private func conversation(for bot: Bot) -> BotConversation {
    let session = environment.projectList.session(bot.sessionId, serverId: bot.serverId)
    return BotConversation(bot: bot, session: session, activity: activity(of: session), isUnread: isUnread(session))
  }

  private func activity(of session: ChatSession?) -> BotConversation.Activity {
    guard let session, let store else { return .idle }

    if store.hasUnreadError(session) { return .failed }
    if store.isWaitingOnUser(session) { return .waitingOnUser }
    if store.isInProgress(session) { return .working }
    return .idle
  }

  private func isUnread(_ session: ChatSession?) -> Bool {
    guard let session, let store else { return false }

    return store.unreadCount(session) > 0 || store.hasUnreadError(session)
  }
}
