import Foundation

@MainActor
final class ActiveTranscriptProjectionFallback {
  private(set) lazy var projection = ActiveTranscriptProjection()

  nonisolated init() {}
}
