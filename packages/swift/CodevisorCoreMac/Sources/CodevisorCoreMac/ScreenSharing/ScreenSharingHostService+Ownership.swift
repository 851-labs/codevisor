import CodevisorClient
import Foundation

extension ScreenSharingHostService {
  typealias Owner = ScreenSharingHostLease.Owner

  static let realDisplayWait = (interval: Duration.milliseconds(100), attempts: 30)
  static let endpointUnavailable = "This Mac's screen-sharing endpoint isn't available."

  var inUse: ServerScreenSharingReply { ScreenSharingHostRefusal.inUse(by: current?.owner.name).reply }

  func describingSession(
    _ reply: ServerScreenSharingReply, for request: ServerScreenSharingRequest
  ) -> ServerScreenSharingReply {
    var reply = reply
    reply.abilities = [ServerScreenSharingReply.appSessions]
    guard request.app != nil, ["connecting", "viewing"].contains(reply.status), let current,
      current.owner == .init(request)
    else { return reply }

    reply.display = current.display
    reply.displays = current.displays
    return reply
  }

  func refusalBeforeStarting(_ request: ServerScreenSharingRequest) -> ServerScreenSharingReply? {
    let owner = Owner(request)
    guard owner.appKey != nil, request.intent != .open else { return nil }

    if let lastEnd, lastEnd.owner == owner, lastEnd.ending.waitsForAnOpen { return lastEnd.ending.reply }
    if let holder = displacer(of: owner) { return ScreenSharingHostRefusal.inUse(by: holder.name).reply }
    return nil
  }

  func sessionlessReply(to owner: Owner) -> ServerScreenSharingReply {
    if let lastEnd, lastEnd.owner == owner { return lastEnd.ending.reply }
    if let holder = displacer(of: owner) { return ScreenSharingHostEnding.takenOver(by: holder.name).reply }
    return .init(status: "stopped", message: "Screen sharing ended on the host Mac.")
  }

  func displace(
    _ old: ScreenSharingHostSession, for request: ServerScreenSharingRequest, attempt: UUID
  ) async -> ServerScreenSharingReply? {
    let owner = Owner(request)
    switch owner.admission(against: old.owner, intent: request.intent) {
    case .refused: return inUse
    case .replacesOwn: await end(old)
    case .takesOver:
      if let refusal = await takeoverRefusal(request) { return refusal }
      guard !isShutdown, pendingStarts[attempt] != nil else { return .init(status: "stopped") }
      guard current === old else { return nil }

      displaced = (old.owner, owner)
      await end(old)
    }
    return nil
  }

  func displaysToShare(with owner: Owner) async throws -> [Display] {
    var available = try await enumerateDisplays()
    var waits = 0
    while displayChoice.awaitsRealDisplay(for: owner, among: available), waits < Self.realDisplayWait.attempts {
      try await Task.sleep(for: Self.realDisplayWait.interval)
      available = try await enumerateDisplays()
      waits += 1
    }
    return available
  }

  func refreshDisplays(of session: ScreenSharingHostSession) async {
    guard session.owner.appKey != nil, let available = try? await enumerateDisplays(), current === session else {
      return
    }

    session.displays = available.map(\.description)
  }

  func forgetDisplacement(endedBy session: ScreenSharingHostSession) {
    guard displaced?.by == session.owner, !pendingStarts.values.contains(session.owner) else { return }

    displaced = nil
  }

  private func displacer(of owner: Owner) -> Owner? {
    guard let displaced, displaced.owner == owner else { return nil }

    let holdsOrIsStarting = current?.owner == displaced.by || pendingStarts.values.contains(displaced.by)
    return holdsOrIsStarting ? displaced.by : nil
  }

  private func takeoverRefusal(_ request: ServerScreenSharingRequest) async -> ServerScreenSharingReply? {
    guard startMedia(request) != nil else { return .init(status: "failed", message: "Invalid Screen Sharing request.") }
    guard captureAccess() else { return ScreenSharingHostRefusal.permissionMissing.reply }
    guard mediaEndpoint.isAvailable, await mediaEndpointHandle() != nil else {
      return .init(status: "failed", message: Self.endpointUnavailable)
    }

    do {
      return try await enumerateDisplays().isEmpty ? ScreenSharingHostRefusal.noDisplay.reply : nil
    } catch { return .init(status: "failed", message: error.localizedDescription) }
  }
}
