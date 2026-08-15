import Foundation

/// The first-send surface owns a short-lived visual replica of a navigation
/// stack. Home's ordinary workspace route is mounted underneath before the
/// animation begins and becomes authoritative as soon as the morph ends.
enum NewChatPromotionRoute: Hashable {
    case workspace
}
