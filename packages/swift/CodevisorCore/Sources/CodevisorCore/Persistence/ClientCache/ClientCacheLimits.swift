import Foundation

struct ClientCacheLimits: Sendable {
  var transcriptAge: TimeInterval = 30 * 24 * 60 * 60
  var transcriptBytes = 64 * 1024 * 1024
  var fileAge: TimeInterval = 30 * 24 * 60 * 60
  var fileBytes = 200 * 1024 * 1024
  var largestFileBytes = 25 * 1024 * 1024
  var queuedSendAge: TimeInterval = 7 * 24 * 60 * 60

  static let standard = ClientCacheLimits()
}
