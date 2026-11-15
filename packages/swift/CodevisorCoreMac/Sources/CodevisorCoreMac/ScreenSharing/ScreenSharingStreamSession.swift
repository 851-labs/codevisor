import Foundation

@MainActor
protocol ScreenSharingStreamSession: AnyObject {
  var attempt: UUID { get }
  var token: String? { get }
}
