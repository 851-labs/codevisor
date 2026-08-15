/// State groups used ahead of recency when the sidebar is ordered by last
/// updated. Lower values appear first: unread (finished, reviewable) chats
/// rank above in-progress (nothing to act on yet) ones. Note the tier a
/// session is *classified* into follows the leading icon's precedence, not
/// this rank order — see `SidebarView.sessionPriority(for:)`.
enum SidebarSessionPriority: Int {
    case errored
    case waitingForUser
    case unread
    case inProgress
    case idle
}
