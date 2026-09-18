import Foundation

extension TranscriptRowProjectionCache {
  /// The optimistic first send shows the same "Waiting on harness…" line the
  /// live turn will replace it with, as soon as nothing local stands in the
  /// way: every setup phase has succeeded (or there is none) and no failure
  /// or connection-recovery state owns the transcript's tail. Connect, the
  /// runtime-configuration replay and the prompt round trip all happen
  /// behind this line instead of a frozen transcript.
  static func showsOptimisticAgentActivity(_ input: TranscriptProjectionInput) -> Bool {
    guard input.activityMessage == nil, input.sessionErrorMessage == nil else { return false }
    if case .failed = input.status { return false }
    return input.setupPhases.allSatisfy(\.isSucceeded)
  }
}
