enum ScreenSharingV2AdmissionRetry {
  private static let shortestUs = 1_000
  private static let longestUs = 8_000

  static func delayNs(after admission: ScreenSharingMediaAdmission) -> Int64 {
    Int64(min(longestUs, max(shortestUs, drainUs(admission)))) * 1_000
  }

  private static func drainUs(_ admission: ScreenSharingMediaAdmission) -> Int {
    guard admission.estimateKbps > 0 else { return longestUs }

    return Int(clamping: admission.backlogBytes * 8_000 / admission.estimateKbps)
  }
}
